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

/// `[retention]` 設定。各区分の保持日数。0 は無期限保持を意味する。
pub type Retention {
  Retention(succeeded_days: Int, dead_letter_days: Int, events_days: Int)
}

/// prune 1 回(または dry-run 1 回)の削除対象件数。deliveries は
/// succeeded / dead_letter の区分別。
pub type PruneCounts {
  PruneCounts(succeeded: Int, dead_letter: Int, events: Int)
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
    token: Int,
  )
  MarkRetry(
    reply: Subject(Result(Int, sqlight.Error)),
    id: String,
    attempts: Int,
    next_attempt_at: Int,
    error: String,
    now_ms: Int,
    token: Int,
  )
  MarkDead(
    reply: Subject(Result(Int, sqlight.Error)),
    id: String,
    attempts: Int,
    error: String,
    now_ms: Int,
    token: Int,
  )
  ReapStale(
    reply: Subject(Result(Int, sqlight.Error)),
    cutoff_ms: Int,
    now_ms: Int,
  )
  ListDead(reply: Subject(Result(List(Delivery), sqlight.Error)))
  RetryDead(reply: Subject(Result(Int, sqlight.Error)), id: String, now_ms: Int)
  DeleteDead(reply: Subject(Result(Int, sqlight.Error)), id: String)
  // #30: retention prune。PruneDryRun は削除せず件数だけ返す(rollback)。
  Prune(
    reply: Subject(Result(PruneCounts, sqlight.Error)),
    now_ms: Int,
    retention: Retention,
  )
  PruneDryRun(
    reply: Subject(Result(PruneCounts, sqlight.Error)),
    now_ms: Int,
    retention: Retention,
  )
  PendingCount(reply: Subject(Result(Int, sqlight.Error)))
  Ping(reply: Subject(Result(Nil, sqlight.Error)))
  // #31: read-only ops CLI queries. 参照のみで状態を変更しない。
  ReadStatus(reply: Subject(Result(StatusSnapshot, sqlight.Error)))
  ListEvents(
    reply: Subject(Result(List(Event), sqlight.Error)),
    source: Option(String),
    event_type: Option(String),
    limit: Int,
  )
  ListEventDeliveries(
    reply: Subject(Result(List(Delivery), sqlight.Error)),
    event_id: String,
  )
  ListDeliveries(
    reply: Subject(Result(List(Delivery), sqlight.Error)),
    status: Option(DeliveryStatus),
    destination: Option(String),
    limit: Int,
  )
  GetDelivery(reply: Subject(Result(Delivery, sqlight.Error)), id: String)
}

const schema = "
pragma foreign_keys = on;
pragma busy_timeout = 5000;
pragma journal_mode = wal;
-- WAL でも synchronous = full で各コミットを fsync する。
-- 202 応答はコミット完了後なので、電源断でも受理済み配送は失われない。
pragma synchronous = full;

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
  // updated_at が claim 世代 token を兼ねる。reap と claim が同じミリ秒に
  // 重なっても前値と衝突しないよう、必ず直前の値より大きくする。
  // RETURNING で返る updated_at がそのまま mark_* の token になる。
  sqlight.query(
    "update deliveries
     set status = 'delivering', updated_at = max(?, updated_at + 1)
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
/// token は claim 時に返った updated_at(claim 世代)。
/// reaper に奪取された後の旧ワーカーの遅延完了は 0 件になり、
/// 呼出側は確定しなかったことを検知できる。
pub fn mark_success(
  conn: sqlight.Connection,
  id: String,
  attempts: Int,
  now_ms: Int,
  token: Int,
) -> Result(Int, sqlight.Error) {
  update_delivery(conn, id, "succeeded", attempts, now_ms, now_ms, None, token)
}

/// delivering の行にだけ効き、かつ token(claim 時の updated_at)が現在値と
/// 一致する行にだけ効く。戻り値は更新件数。
/// reaper に奪取されて新世代が claim した後の旧ワーカーの遅延完了は
/// 0 件になり、呼出側は確定しなかったことを検知できる。
pub fn mark_retry(
  conn: sqlight.Connection,
  id: String,
  attempts: Int,
  next_attempt_at: Int,
  error: String,
  now_ms: Int,
  token: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = 'retry_scheduled', attempts = ?, next_attempt_at = ?,
         last_attempt_at = ?, last_error = ?, updated_at = ?
     where id = ? and status = 'delivering' and updated_at = ?",
    on: conn,
    with: [
      sqlight.int(attempts),
      sqlight.int(next_attempt_at),
      sqlight.int(now_ms),
      sqlight.text(error),
      sqlight.int(now_ms),
      sqlight.text(id),
      sqlight.int(token),
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
  token: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = 'dead_letter', attempts = ?, last_attempt_at = ?,
         last_error = ?, updated_at = ?
     where id = ? and status = 'delivering' and updated_at = ?",
    on: conn,
    with: [
      sqlight.int(attempts),
      sqlight.int(now_ms),
      sqlight.text(error),
      sqlight.int(now_ms),
      sqlight.text(id),
      sqlight.int(token),
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
  token: Int,
) -> Result(Int, sqlight.Error) {
  // mark_* は delivering の間だけ有効。さらに claim 世代 token(claim 時に
  // 返った updated_at)が現在値と一致する行にだけ効く。reaper 後に新世代が
  // claim した行を、旧ワーカーの遅延完了が上書きできない(F2)。
  use _ <- result.try(sqlight.query(
    "update deliveries
     set status = ?, attempts = ?, last_attempt_at = ?, last_error = ?,
         updated_at = ?
     where id = ? and status = 'delivering' and updated_at = ?",
    on: conn,
    with: [
      sqlight.text(status),
      sqlight.int(attempts),
      sqlight.int(last_attempt_at),
      sqlight.nullable(sqlight.text, error),
      sqlight.int(now_ms),
      sqlight.text(id),
      sqlight.int(token),
    ],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
}

/// updated_at が cutoff_ms より前の delivering を pending に戻し、
/// 戻した件数を返す。
/// 戻した行の updated_at は now_ms に置き換わるため、旧 claim の token は
/// 失効し、旧ワーカーの mark_* は以後 0 件になる(F2)。
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

// ---------------------------------------------------------------------------
// #30: retention prune
// 削除対象は succeeded / dead_letter の terminal な Delivery と、
// 参照する Delivery が残っていない古い Event(孤児)だけ。
// pending / delivering / retry_scheduled は絶対に消さない。
// ---------------------------------------------------------------------------

/// 1 日(ミリ秒)。日数はこの単位で now_ms から引いて cutoff にする。
const ms_per_day = 86_400_000

/// retention のいずれかの区分が 0 より大きければ自動 prune が有効。
pub fn retention_enabled(retention: Retention) -> Bool {
  let Retention(succeeded_days:, dead_letter_days:, events_days:) = retention
  succeeded_days > 0 || dead_letter_days > 0 || events_days > 0
}

/// retention に従って terminal な行を削除する。1 トランザクションで
/// deliveries → 孤児 events の順に消し、失敗時は全体をロールバックする。
/// 日数 0 の区分は削除しない(無期限保持)。
pub fn prune(
  conn: sqlight.Connection,
  now_ms: Int,
  retention: Retention,
) -> Result(PruneCounts, sqlight.Error) {
  use _ <- result.try(sqlight.exec("begin immediate", conn))
  let outcome = prune_in_tx(conn, now_ms, retention)
  case outcome {
    Ok(counts) ->
      case sqlight.exec("commit", conn) {
        Ok(_) -> Ok(counts)
        Error(error) -> {
          let _ = sqlight.exec("rollback", conn)
          Error(error)
        }
      }
    Error(error) -> {
      let _ = sqlight.exec("rollback", conn)
      Error(error)
    }
  }
}

/// prune と同じ削除判定を実行して件数だけ返し、トランザクションは
/// ロールバックする(dry-run)。どの行も変更しない。
pub fn prune_dry_run(
  conn: sqlight.Connection,
  now_ms: Int,
  retention: Retention,
) -> Result(PruneCounts, sqlight.Error) {
  use _ <- result.try(sqlight.exec("begin immediate", conn))
  let outcome = prune_in_tx(conn, now_ms, retention)
  let _ = sqlight.exec("rollback", conn)
  outcome
}

fn prune_in_tx(
  conn: sqlight.Connection,
  now_ms: Int,
  retention: Retention,
) -> Result(PruneCounts, sqlight.Error) {
  let Retention(succeeded_days:, dead_letter_days:, events_days:) = retention
  use succeeded <- result.try(case succeeded_days > 0 {
    True ->
      delete_old_deliveries(
        conn,
        "succeeded",
        now_ms - succeeded_days * ms_per_day,
      )
    False -> Ok(0)
  })
  use dead_letter <- result.try(case dead_letter_days > 0 {
    True ->
      delete_old_deliveries(
        conn,
        "dead_letter",
        now_ms - dead_letter_days * ms_per_day,
      )
    False -> Ok(0)
  })
  // 直前に消した Delivery の Event も孤児として対象になる(FK 安全な順序)。
  use events <- result.try(case events_days > 0 {
    True -> delete_old_orphan_events(conn, now_ms - events_days * ms_per_day)
    False -> Ok(0)
  })
  Ok(PruneCounts(succeeded:, dead_letter:, events:))
}

/// status が一致し updated_at が cutoff より前の Delivery を削除し、件数を返す。
fn delete_old_deliveries(
  conn: sqlight.Connection,
  status: String,
  cutoff_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "delete from deliveries where status = ? and updated_at < ?",
    on: conn,
    with: [sqlight.text(status), sqlight.int(cutoff_ms)],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
}

/// received_at が cutoff より前で、参照する Delivery が 1 件も残っていない
/// Event だけを削除し、件数を返す。FK 制約を壊さないよう孤児のみ対象。
fn delete_old_orphan_events(
  conn: sqlight.Connection,
  cutoff_ms: Int,
) -> Result(Int, sqlight.Error) {
  use _ <- result.try(sqlight.query(
    "delete from events
     where received_at < ?
       and not exists (
         select 1 from deliveries where deliveries.event_id = events.id
       )",
    on: conn,
    with: [sqlight.int(cutoff_ms)],
    expecting: decode.success(Nil),
  ))
  changed_rows(conn)
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
  token: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkSuccess(reply:, id:, attempts:, now_ms:, token:)
  })
}

pub fn call_mark_retry(
  store: Store,
  id: String,
  attempts: Int,
  next_attempt_at: Int,
  error: String,
  now_ms: Int,
  token: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkRetry(reply:, id:, attempts:, next_attempt_at:, error:, now_ms:, token:)
  })
}

pub fn call_mark_dead(
  store: Store,
  id: String,
  attempts: Int,
  error: String,
  now_ms: Int,
  token: Int,
) -> Result(Int, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    MarkDead(reply:, id:, attempts:, error:, now_ms:, token:)
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

pub fn call_prune(
  store: Store,
  now_ms: Int,
  retention: Retention,
) -> Result(PruneCounts, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { Prune(reply:, now_ms:, retention:) })
}

pub fn call_prune_dry_run(
  store: Store,
  now_ms: Int,
  retention: Retention,
) -> Result(PruneCounts, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    PruneDryRun(reply:, now_ms:, retention:)
  })
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
    MarkSuccess(reply:, id:, attempts:, now_ms:, token:) ->
      process.send(reply, mark_success(conn, id, attempts, now_ms, token))
    MarkRetry(reply:, id:, attempts:, next_attempt_at:, error:, now_ms:, token:) ->
      process.send(
        reply,
        mark_retry(conn, id, attempts, next_attempt_at, error, now_ms, token),
      )
    MarkDead(reply:, id:, attempts:, error:, now_ms:, token:) ->
      process.send(reply, mark_dead(conn, id, attempts, error, now_ms, token))
    ReapStale(reply:, cutoff_ms:, now_ms:) ->
      process.send(reply, reap_stale_delivering(conn, cutoff_ms, now_ms))
    ListDead(reply:) -> process.send(reply, list_dead(conn))
    RetryDead(reply:, id:, now_ms:) ->
      process.send(reply, retry_dead(conn, id, now_ms))
    DeleteDead(reply:, id:) -> process.send(reply, delete_dead(conn, id))
    Prune(reply:, now_ms:, retention:) ->
      process.send(reply, prune(conn, now_ms, retention))
    PruneDryRun(reply:, now_ms:, retention:) ->
      process.send(reply, prune_dry_run(conn, now_ms, retention))
    PendingCount(reply:) -> process.send(reply, count_pending(conn))
    Ping(reply:) -> process.send(reply, ping(conn))
    ReadStatus(reply:) -> process.send(reply, status_snapshot(conn))
    ListEvents(reply:, source:, event_type:, limit:) ->
      process.send(reply, list_events(conn, source, event_type, limit))
    ListEventDeliveries(reply:, event_id:) ->
      process.send(reply, list_event_deliveries(conn, event_id))
    ListDeliveries(reply:, status:, destination:, limit:) ->
      process.send(reply, list_deliveries(conn, status, destination, limit))
    GetDelivery(reply:, id:) -> process.send(reply, get_delivery(conn, id))
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

/// --- #31: read-only ops CLI 用クエリ（追加分のみ。参照で状態を変えない） ---
/// DeliveryStatus の DB 表記。読み出しフィルタと表示に使う。
pub fn status_name(status: DeliveryStatus) -> String {
  case status {
    Pending -> "pending"
    Delivering -> "delivering"
    RetryScheduled -> "retry_scheduled"
    Succeeded -> "succeeded"
    DeadLetter -> "dead_letter"
  }
}

pub type StatusSnapshot {
  StatusSnapshot(
    counts: List(#(DeliveryStatus, Int)),
    oldest_open_since_ms: Option(Int),
  )
}

/// `vectum status` 用の 1 回のスナップショット。
/// pending / retry_scheduled の中で updated_at が最も古い行の時刻も返す。
pub fn status_snapshot(
  conn: sqlight.Connection,
) -> Result(StatusSnapshot, sqlight.Error) {
  use counts <- result.try(counts_by_status(conn))
  use oldest <- result.try(oldest_open(conn))
  Ok(StatusSnapshot(counts:, oldest_open_since_ms: oldest))
}

pub fn counts_by_status(
  conn: sqlight.Connection,
) -> Result(List(#(DeliveryStatus, Int)), sqlight.Error) {
  sqlight.query(
    "select status, count(*) from deliveries group by status",
    on: conn,
    with: [],
    expecting: {
      use raw <- decode.field(0, decode.string)
      use count <- decode.field(1, decode.int)
      decode.success(#(parse_status(raw), count))
    },
  )
}

/// 存在しなければ None。min(updated_at) は idx_deliveries_due(status, ...) の
/// status プリフィックスで済むため安価。
pub fn oldest_open(
  conn: sqlight.Connection,
) -> Result(Option(Int), sqlight.Error) {
  use rows <- result.try(
    sqlight.query(
      "select min(updated_at) from deliveries
       where status in ('pending', 'retry_scheduled')",
      on: conn,
      with: [],
      expecting: {
        use ms <- decode.field(0, decode.optional(decode.int))
        decode.success(ms)
      },
    ),
  )
  case rows {
    [oldest] -> Ok(oldest)
    _ -> Ok(None)
  }
}

/// received_at の新しい順。絞り込みは SQL NULL で無効化する
/// (`? is null or source = ?`)。
pub fn list_events(
  conn: sqlight.Connection,
  source: Option(String),
  event_type: Option(String),
  limit: Int,
) -> Result(List(Event), sqlight.Error) {
  sqlight.query(
    "select id, source, event_type, timestamp, payload, metadata
     from events
     where (? is null or source = ?)
       and (? is null or event_type = ?)
     order by received_at desc
     limit ?",
    on: conn,
    with: [
      sqlight.nullable(sqlight.text, source),
      sqlight.nullable(sqlight.text, source),
      sqlight.nullable(sqlight.text, event_type),
      sqlight.nullable(sqlight.text, event_type),
      sqlight.int(limit),
    ],
    expecting: event_row_decoder(),
  )
}

/// 1 Event に紐づく全 Delivery(updated_at の新しい順)。
/// (event_id, destination) の unique index で絞るため LIMIT 不要。
pub fn list_event_deliveries(
  conn: sqlight.Connection,
  event_id: String,
) -> Result(List(Delivery), sqlight.Error) {
  sqlight.query(
    "select id, event_id, destination, status, attempts, next_attempt_at,
            last_attempt_at, last_error, created_at, updated_at
     from deliveries
     where event_id = ?
     order by updated_at desc",
    on: conn,
    with: [sqlight.text(event_id)],
    expecting: delivery_decoder(),
  )
}

pub fn list_deliveries(
  conn: sqlight.Connection,
  status: Option(DeliveryStatus),
  destination: Option(String),
  limit: Int,
) -> Result(List(Delivery), sqlight.Error) {
  let status_text = option.map(status, status_name)
  sqlight.query(
    "select id, event_id, destination, status, attempts, next_attempt_at,
            last_attempt_at, last_error, created_at, updated_at
     from deliveries
     where (? is null or status = ?)
       and (? is null or destination = ?)
     order by updated_at desc
     limit ?",
    on: conn,
    with: [
      sqlight.nullable(sqlight.text, status_text),
      sqlight.nullable(sqlight.text, status_text),
      sqlight.nullable(sqlight.text, destination),
      sqlight.nullable(sqlight.text, destination),
      sqlight.int(limit),
    ],
    expecting: delivery_decoder(),
  )
}

/// 存在しない ID は Notfound の Error(get_event と同じ流儀)。
pub fn get_delivery(
  conn: sqlight.Connection,
  id: String,
) -> Result(Delivery, sqlight.Error) {
  use rows <- result.try(sqlight.query(
    "select id, event_id, destination, status, attempts, next_attempt_at,
              last_attempt_at, last_error, created_at, updated_at
       from deliveries
       where id = ?",
    on: conn,
    with: [sqlight.text(id)],
    expecting: delivery_decoder(),
  ))
  case rows {
    [delivery] -> Ok(delivery)
    _ -> Error(sqlight.SqlightError(sqlight.Notfound, "delivery not found", -1))
  }
}

pub fn call_status_snapshot(
  store: Store,
) -> Result(StatusSnapshot, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { ReadStatus(reply:) })
}

pub fn call_list_events(
  store: Store,
  source: Option(String),
  event_type: Option(String),
  limit: Int,
) -> Result(List(Event), sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    ListEvents(reply:, source:, event_type:, limit:)
  })
}

pub fn call_list_event_deliveries(
  store: Store,
  event_id: String,
) -> Result(List(Delivery), sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    ListEventDeliveries(reply:, event_id:)
  })
}

pub fn call_list_deliveries(
  store: Store,
  status: Option(DeliveryStatus),
  destination: Option(String),
  limit: Int,
) -> Result(List(Delivery), sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) {
    ListDeliveries(reply:, status:, destination:, limit:)
  })
}

pub fn call_get_delivery(
  store: Store,
  id: String,
) -> Result(Delivery, sqlight.Error) {
  try_call(store.subject, 5000, fn(reply) { GetDelivery(reply:, id:) })
}
