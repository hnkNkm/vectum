import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight
import vectum/event.{type Event, Event}

pub type DeliveryStatus {
  Pending
  Delivering
  RetryScheduled
  Succeeded
  DeadLetter
}

pub type Delivery {
  Delivery(
    id: String,
    event_id: String,
    destination: String,
    status: DeliveryStatus,
    attempts: Int,
    next_attempt_at: Int,
    last_attempt_at: Option(Int),
    last_error: Option(String),
    created_at: Int,
    updated_at: Int,
  )
}

pub type Store {
  Store(subject: Subject(Message))
}

pub type Message {
  Accept(
    reply: Subject(Result(List(Delivery), sqlight.Error)),
    event: Event,
    destinations: List(String),
    now_ms: Int,
    delivery_ids: List(String),
  )
  GetEvent(reply: Subject(Result(Event, sqlight.Error)), id: String)
  ClaimDue(
    reply: Subject(Result(List(Delivery), sqlight.Error)),
    now_ms: Int,
    limit: Int,
  )
  MarkSuccess(
    reply: Subject(Result(Int, sqlight.Error)),
    id: String,
    attempts: Int,
    now_ms: Int,
  )
  MarkRetry(
    reply: Subject(Result(Int, sqlight.Error)),
    id: String,
    attempts: Int,
    next_attempt_at: Int,
    error: String,
    now_ms: Int,
  )
  MarkDead(
    reply: Subject(Result(Int, sqlight.Error)),
    id: String,
    attempts: Int,
    error: String,
    now_ms: Int,
  )
  ReapStale(
    reply: Subject(Result(Int, sqlight.Error)),
    cutoff_ms: Int,
    now_ms: Int,
  )
  ListDead(reply: Subject(Result(List(Delivery), sqlight.Error)))
  RetryDead(reply: Subject(Result(Int, sqlight.Error)), id: String, now_ms: Int)
  DeleteDead(reply: Subject(Result(Int, sqlight.Error)), id: String)
  PendingCount(reply: Subject(Result(Int, sqlight.Error)))
  Ping(reply: Subject(Result(Nil, sqlight.Error)))
}

const schema = "
pragma foreign_keys = on;
pragma busy_timeout = 5000;
pragma journal_mode = wal;
pragma synchronous = normal;

create table if not exists events (
  id text primary key,
  source text not null,
  event_type text not null,
  timestamp text not null,
  received_at integer not null,
  payload text not null,
  metadata text not null
);

create table if not exists deliveries (
  id text primary key,
  event_id text not null references events(id),
  destination text not null,
  status text not null,
  attempts integer not null,
  next_attempt_at integer not null,
  last_attempt_at integer,
  last_error text,
  created_at integer not null,
  updated_at integer not null,
  unique(event_id, destination)
);

create index if not exists idx_deliveries_due
  on deliveries(status, next_attempt_at);
"

pub fn connect(path: String) -> Result(sqlight.Connection, sqlight.Error) {
  sqlight.open(path)
}

/// プロセス起動時に一度だけ呼ぶ全件復旧。
/// delivering を pending に戻し、未完了配送を再開する。
/// actor 再起動時には呼ばない(二重配送防止)。滞留は reaper が拾う。
pub fn open_and_recover(path: String, now_ms: Int) -> Result(Int, String) {
  use conn <- result.try(connect(path) |> result.map_error(string.inspect))
  let recovered = case migrate(conn) {
    Error(error) -> Error(string.inspect(error))
    Ok(_) -> recover(conn, now_ms) |> result.map_error(string.inspect)
  }
  let _ = sqlight.close(conn)
  recovered
}

pub fn migrate(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  sqlight.exec(schema, conn)
}

pub fn recover(
  conn: sqlight.Connection,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries set status = 'pending', updated_at = ?
     where status = 'delivering'",
    on: conn,
    with: [sqlight.int(now_ms)],
    expecting: decode.success(Nil),
  ))
  count_pending(conn)
}

pub fn accept(
  conn: sqlight.Connection,
  event: Event,
  destinations: List(String),
  now_ms: Int,
  delivery_ids: List(String),
) -> Result(List(Delivery), sqlight.Error) {
  let unique = unique_keep_order(destinations)
  use _ <- result.try(sqlight.exec("begin immediate", conn))
  let result = insert_accepted(conn, event, unique, now_ms, delivery_ids)
  case result {
    Ok(deliveries) -> {
      case sqlight.exec("commit", conn) {
        Ok(_) -> Ok(deliveries)
        Error(error) -> {
          let _ = sqlight.exec("rollback", conn)
          Error(error)
        }
      }
    }
    Error(error) -> {
      let _ = sqlight.exec("rollback", conn)
      Error(error)
    }
  }
}

fn insert_accepted(
  conn: sqlight.Connection,
  event: Event,
  destinations: List(String),
  now_ms: Int,
  delivery_ids: List(String),
) -> Result(List(Delivery), sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "insert into events (id, source, event_type, timestamp, received_at, payload, metadata)
     values (?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(event.id),
      sqlight.text(event.source),
      sqlight.text(event.event_type),
      sqlight.text(event.timestamp),
      sqlight.int(now_ms),
      sqlight.text(event.to_json_string(event.data)),
      sqlight.text(metadata_json(event.metadata)),
    ],
    expecting: decode.success(Nil),
  ))

  use ids <- result.try(pad_ids(delivery_ids, list.length(destinations)))
  list.zip(destinations, ids)
  |> list.try_map(fn(pair) {
    let #(destination, delivery_id) = pair
    let delivery =
      Delivery(
        id: delivery_id,
        event_id: event.id,
        destination:,
        status: Pending,
        attempts: 0,
        next_attempt_at: now_ms,
        last_attempt_at: None,
        last_error: None,
        created_at: now_ms,
        updated_at: now_ms,
      )
    use _ <- result.try(sqlight.query(
      "insert into deliveries (
         id, event_id, destination, status, attempts,
         next_attempt_at, last_attempt_at, last_error, created_at, updated_at
       ) values (?, ?, ?, 'pending', 0, ?, null, null, ?, ?)",
      on: conn,
      with: [
        sqlight.text(delivery.id),
        sqlight.text(delivery.event_id),
        sqlight.text(delivery.destination),
        sqlight.int(now_ms),
        sqlight.int(now_ms),
        sqlight.int(now_ms),
      ],
      expecting: decode.success(Nil),
    ))
    Ok(delivery)
  })
}

fn unique_keep_order(names: List(String)) -> List(String) {
  let #(_seen, unique) =
    list.fold(names, #(dict.new(), []), fn(acc, name) {
      let #(seen, out) = acc
      case dict.has_key(seen, name) {
        True -> acc
        False -> #(dict.insert(seen, name, True), list.append(out, [name]))
      }
    })
  unique
}

fn pad_ids(
  ids: List(String),
  needed: Int,
) -> Result(List(String), sqlight.Error) {
  let have = list.length(ids)
  case have >= needed {
    True -> Ok(list.take(ids, needed))
    False ->
      Error(sqlight.SqlightError(
        sqlight.Misuse,
        "delivery_ids shorter than destinations",
        -1,
      ))
  }
}

pub fn get_event(
  conn: sqlight.Connection,
  id: String,
) -> Result(Event, sqlight.Error) {
  use rows <- result.try(sqlight.query(
    "select id, source, event_type, timestamp, payload, metadata
     from events where id = ?",
    on: conn,
    with: [sqlight.text(id)],
    expecting: event_row_decoder(),
  ))
  case rows {
    [event] -> Ok(event)
    _ -> Error(sqlight.SqlightError(sqlight.Notfound, "event not found", -1))
  }
}

pub fn claim_due(
  conn: sqlight.Connection,
  now_ms: Int,
  limit: Int,
) -> Result(List(Delivery), sqlight.Error) {
  sqlight.query(
    "update deliveries set status = 'delivering', updated_at = ?
     where id in (
       select id from deliveries
       where status in ('pending', 'retry_scheduled')
         and next_attempt_at <= ?
       order by next_attempt_at
       limit ?
     )
     returning id, event_id, destination, status, attempts, next_attempt_at,
            last_attempt_at, last_error, created_at, updated_at",
    on: conn,
    with: [sqlight.int(now_ms), sqlight.int(now_ms), sqlight.int(limit)],
    expecting: delivery_decoder(),
  )
}

/// delivering の行にだけ効く。戻り値は更新件数。
/// reaper に奪取された後の旧ワーカーの遅延完了は 0 件になり、
/// 呼出側は確定しなかったことを検知できる。
pub fn mark_success(
  conn: sqlight.Connection,
  id: String,
  attempts: Int,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  update_delivery(conn, id, "succeeded", attempts, now_ms, now_ms, None)
}

pub fn mark_retry(
  conn: sqlight.Connection,
  id: String,
  attempts: Int,
  next_attempt_at: Int,
  error: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = 'retry_scheduled', attempts = ?, next_attempt_at = ?,
         last_attempt_at = ?, last_error = ?, updated_at = ?
     where id = ? and status = 'delivering'",
    on: conn,
    with: [
      sqlight.int(attempts),
      sqlight.int(next_attempt_at),
      sqlight.int(now_ms),
      sqlight.text(error),
      sqlight.int(now_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
}

pub fn mark_dead(
  conn: sqlight.Connection,
  id: String,
  attempts: Int,
  error: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = 'dead_letter', attempts = ?, last_attempt_at = ?,
         last_error = ?, updated_at = ?
     where id = ? and status = 'delivering'",
    on: conn,
    with: [
      sqlight.int(attempts),
      sqlight.int(now_ms),
      sqlight.text(error),
      sqlight.int(now_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
}

fn update_delivery(
  conn: sqlight.Connection,
  id: String,
  status: String,
  attempts: Int,
  last_attempt_at: Int,
  now_ms: Int,
  error: Option(String),
) -> Result(Int, sqlight.Error) {
  // mark_* は delivering の間だけ有効。reaper 後の旧ワーカーの遅延完了が、
  // 新しい claim の結果を上書きしないようにする。
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = ?, attempts = ?, last_attempt_at = ?, last_error = ?,
         updated_at = ?
     where id = ? and status = 'delivering'",
    on: conn,
    with: [
      sqlight.text(status),
      sqlight.int(attempts),
      sqlight.int(last_attempt_at),
      sqlight.nullable(sqlight.text, error),
      sqlight.int(now_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
}

/// updated_at が cutoff_ms より前の delivering を pending に戻し、
/// 戻した件数を返す。
pub fn reap_stale_delivering(
  conn: sqlight.Connection,
  cutoff_ms: Int,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = 'pending', updated_at = ?
     where status = 'delivering' and updated_at < ?",
    on: conn,
    with: [sqlight.int(now_ms), sqlight.int(cutoff_ms)],
    expecting: decode.success(Nil),
  ))
  use rows <- result.try(
    sqlight.query("select changes()", on: conn, with: [], expecting: {
      use n <- decode.field(0, decode.int)
      decode.success(n)
    }),
  )
  case rows {
    [n] -> Ok(n)
    _ -> Ok(0)
  }
}

pub fn list_dead(
  conn: sqlight.Connection,
) -> Result(List(Delivery), sqlight.Error) {
  sqlight.query(
    "select id, event_id, destination, status, attempts, next_attempt_at,
            last_attempt_at, last_error, created_at, updated_at
     from deliveries
     where status = 'dead_letter'
     order by updated_at",
    on: conn,
    with: [],
    expecting: delivery_decoder(),
  )
}

pub fn retry_dead(
  conn: sqlight.Connection,
  id: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  sqlight.query(
    "update deliveries
     set status = 'pending', attempts = 0, next_attempt_at = ?,
         last_error = null, updated_at = ?
     where id = ? and status = 'dead_letter'",
    on: conn,
    with: [sqlight.int(now_ms), sqlight.int(now_ms), sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.try(fn(_) { changed_rows(conn) })
}

pub fn delete_dead(
  conn: sqlight.Connection,
  id: String,
) -> Result(Int, sqlight.Error) {
  sqlight.query(
    "delete from deliveries where id = ? and status = 'dead_letter'",
    on: conn,
    with: [sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.try(fn(_) { changed_rows(conn) })
}

fn changed_rows(conn: sqlight.Connection) -> Result(Int, sqlight.Error) {
  use rows <- result.try(
    sqlight.query("select changes()", on: conn, with: [], expecting: {
      use n <- decode.field(0, decode.int)
      decode.success(n)
    }),
  )
  case rows {
    [n] -> Ok(n)
    _ -> Ok(0)
  }
}

pub fn count_pending(conn: sqlight.Connection) -> Result(Int, sqlight.Error) {
  use rows <- result.try(
    sqlight.query(
      "select count(*) from deliveries
     where status in ('pending', 'delivering', 'retry_scheduled')",
      on: conn,
      with: [],
      expecting: {
        use n <- decode.field(0, decode.int)
        decode.success(n)
      },
    ),
  )
  case rows {
    [n] -> Ok(n)
    _ -> Ok(0)
  }
}

pub fn ping(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  sqlight.query("select 1", on: conn, with: [], expecting: decode.success(Nil))
  |> result.replace(Nil)
}

pub fn start(path: String) -> Result(Store, String) {
  case start_supervised(path) {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(string.inspect(error))
  }
}

/// Supervisor 配下用。Started をそのまま返す。
pub fn start_supervised(
  path: String,
) -> Result(actor.Started(Store), actor.StartError) {
  actor.new_with_initialiser(2000, fn(subject) {
    case connect(path) {
      Error(error) -> Error(string.inspect(error))
      Ok(conn) ->
        case migrate(conn) {
          Error(error) -> Error(string.inspect(error))
          // ここでは recover() を呼ばない。actor 再起動時に実行中ワーカーの
          // 配送を即 requeue すると二重送信になるため、滞留は reaper に委ねる。
          // 全件復旧はプロセス起動時に open_and_recover で明示的に行う。
          Ok(_) -> {
            actor.initialised(conn)
            |> actor.returning(Store(subject))
            |> Ok
          }
        }
    }
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// process.call は応答なし・先方死で panic するため、監視付き select で待つ。
/// 輸送失敗(timeout / 先方死 / owner 不在)は sqlight.Error に畳んで返す。
/// 呼出側は Error を通常の失敗として扱い、panic しない。
type CallOutcome(a) {
  CallReply(a)
  CalleeDown
}

fn try_call(
  subject: Subject(Message),
  timeout: Int,
  make_request: fn(Subject(Result(t, sqlight.Error))) -> Message,
) -> Result(t, sqlight.Error) {
  let reply_subject = process.new_subject()
  case process.subject_owner(subject) {
    Error(_) ->
      Error(sqlight.SqlightError(
        sqlight.GenericError,
        "storage callee has no owner",
        -1,
      ))
    Ok(callee) -> {
      let monitor = process.monitor(callee)
      process.send(subject, make_request(reply_subject))
      let selector =
        process.new_selector()
        |> process.select_map(reply_subject, CallReply)
        |> process.select_specific_monitor(monitor, fn(_) { CalleeDown })
      let outcome = process.selector_receive(selector, timeout)
      process.demonitor_process(monitor)
      case outcome {
        Ok(CallReply(inner)) -> inner
        Ok(CalleeDown) ->
          Error(sqlight.SqlightError(
            sqlight.Interrupt,
            "storage callee exited",
            -1,
          ))
        Error(_) ->
          Error(sqlight.SqlightError(
            sqlight.BusyTimeout,
            "storage call timeout",
            -1,
          ))
      }
    }
  }
}

pub fn call_accept(
  store: Store,
  event: Event,
  destinations: List(String),
  now_ms: Int,
  delivery_ids: List(String),
) -> Result(List(Delivery), sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    Accept(reply:, event:, destinations:, now_ms:, delivery_ids:)
  })
}

pub fn call_get_event(
  store: Store,
  id: String,
) -> Result(Event, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { GetEvent(reply:, id:) })
}

pub fn call_claim_due(
  store: Store,
  now_ms: Int,
  limit: Int,
) -> Result(List(Delivery), sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { ClaimDue(reply:, now_ms:, limit:) })
}

pub fn call_mark_success(
  store: Store,
  id: String,
  attempts: Int,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkSuccess(reply:, id:, attempts:, now_ms:)
  })
}

pub fn call_mark_retry(
  store: Store,
  id: String,
  attempts: Int,
  next_attempt_at: Int,
  error: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkRetry(reply:, id:, attempts:, next_attempt_at:, error:, now_ms:)
  })
}

pub fn call_mark_dead(
  store: Store,
  id: String,
  attempts: Int,
  error: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkDead(reply:, id:, attempts:, error:, now_ms:)
  })
}

pub fn call_reap_stale(
  store: Store,
  cutoff_ms: Int,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    ReapStale(reply:, cutoff_ms:, now_ms:)
  })
}

pub fn call_list_dead(store: Store) -> Result(List(Delivery), sqlight.Error) {
  try_call(store.subject, 5000, ListDead)
}

pub fn call_retry_dead(
  store: Store,
  id: String,
  now_ms: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { RetryDead(reply:, id:, now_ms:) })
}

pub fn call_delete_dead(
  store: Store,
  id: String,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { DeleteDead(reply:, id:) })
}

pub fn call_pending_count(store: Store) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, PendingCount)
}

pub fn call_ping(store: Store) -> Result(Nil, sqlight.Error) {
  try_call(store.subject, 5000, Ping)
}

fn handle(
  conn: sqlight.Connection,
  message: Message,
) -> actor.Next(sqlight.Connection, Message) {
  case message {
    Accept(reply:, event:, destinations:, now_ms:, delivery_ids:) ->
      process.send(
        reply,
        accept(conn, event, destinations, now_ms, delivery_ids),
      )
    GetEvent(reply:, id:) -> process.send(reply, get_event(conn, id))
    ClaimDue(reply:, now_ms:, limit:) ->
      process.send(reply, claim_due(conn, now_ms, limit))
    MarkSuccess(reply:, id:, attempts:, now_ms:) ->
      process.send(reply, mark_success(conn, id, attempts, now_ms))
    MarkRetry(reply:, id:, attempts:, next_attempt_at:, error:, now_ms:) ->
      process.send(
        reply,
        mark_retry(conn, id, attempts, next_attempt_at, error, now_ms),
      )
    MarkDead(reply:, id:, attempts:, error:, now_ms:) ->
      process.send(reply, mark_dead(conn, id, attempts, error, now_ms))
    ReapStale(reply:, cutoff_ms:, now_ms:) ->
      process.send(reply, reap_stale_delivering(conn, cutoff_ms, now_ms))
    ListDead(reply:) -> process.send(reply, list_dead(conn))
    RetryDead(reply:, id:, now_ms:) ->
      process.send(reply, retry_dead(conn, id, now_ms))
    DeleteDead(reply:, id:) -> process.send(reply, delete_dead(conn, id))
    PendingCount(reply:) -> process.send(reply, count_pending(conn))
    Ping(reply:) -> process.send(reply, ping(conn))
  }
  actor.continue(conn)
}

fn metadata_json(metadata: Dict(String, String)) -> String {
  json.object(
    dict.to_list(metadata)
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
  )
  |> json.to_string
}

fn event_row_decoder() -> decode.Decoder(Event) {
  use id <- decode.field(0, decode.string)
  use source <- decode.field(1, decode.string)
  use event_type <- decode.field(2, decode.string)
  use timestamp <- decode.field(3, decode.string)
  use payload <- decode.field(4, decode.string)
  use metadata_raw <- decode.field(5, decode.string)
  case
    event.parse_json(payload),
    json.parse(metadata_raw, decode.dict(decode.string, decode.string))
  {
    Ok(data), Ok(metadata) ->
      decode.success(Event(
        id:,
        source:,
        event_type:,
        timestamp:,
        data:,
        metadata:,
      ))
    _, _ ->
      decode.failure(
        Event(
          id:,
          source:,
          event_type:,
          timestamp:,
          data: event.Null,
          metadata: dict.new(),
        ),
        expected: "valid event payload and metadata JSON",
      )
  }
}

fn delivery_decoder() -> decode.Decoder(Delivery) {
  use id <- decode.field(0, decode.string)
  use event_id <- decode.field(1, decode.string)
  use destination <- decode.field(2, decode.string)
  use status_raw <- decode.field(3, decode.string)
  use attempts <- decode.field(4, decode.int)
  use next_attempt_at <- decode.field(5, decode.int)
  use last_attempt_at <- decode.field(6, decode.optional(decode.int))
  use last_error <- decode.field(7, decode.optional(decode.string))
  use created_at <- decode.field(8, decode.int)
  use updated_at <- decode.field(9, decode.int)
  decode.success(Delivery(
    id:,
    event_id:,
    destination:,
    status: parse_status(status_raw),
    attempts:,
    next_attempt_at:,
    last_attempt_at:,
    last_error:,
    created_at:,
    updated_at:,
  ))
}

fn parse_status(raw: String) -> DeliveryStatus {
  case raw {
    "pending" -> Pending
    "delivering" -> Delivering
    "retry_scheduled" -> RetryScheduled
    "succeeded" -> Succeeded
    "dead_letter" -> DeadLetter
    _ -> Pending
  }
}
