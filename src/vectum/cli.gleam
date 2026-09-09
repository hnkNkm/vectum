import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import vectum/env
import vectum/event
import vectum/storage.{type Delivery}

pub type Command {
  Run(config: String)
  Validate(config: String)
  DeadList(config: String)
  DeadRetry(config: String, id: String)
  DeadDelete(config: String, id: String)
  // #31: read-only ops CLI
  Status(config: String)
  EventsList(
    config: String,
    source: Option(String),
    event_type: Option(String),
    limit: Int,
  )
  EventsShow(config: String, id: String)
  DeliveriesList(
    config: String,
    status: Option(storage.DeliveryStatus),
    destination: Option(String),
    limit: Int,
  )
  DeliveriesShow(config: String, id: String)
  Help
  Usage(String)
}

/// list 系の絞り込みフラグ。値は raw のまま保持し、
/// サブコマンド側で解釈・検証する(--limit / --status)。
type Flags {
  Flags(
    source: Option(String),
    event_type: Option(String),
    destination: Option(String),
    status_raw: Option(String),
    limit_raw: Option(String),
  )
}

fn empty_flags() -> Flags {
  Flags(
    source: None,
    event_type: None,
    destination: None,
    status_raw: None,
    limit_raw: None,
  )
}

const default_limit = 50

const max_limit = 1000

pub fn default_config_path() -> String {
  case env.get("VECTUM_CONFIG") {
    // 空 (set 済み) は未設定扱いにし、原因不明の読込失敗を避ける。
    Ok(path) ->
      case string.trim(path) {
        "" -> "router.toml"
        _ -> path
      }
    Error(_) -> "router.toml"
  }
}

pub fn parse(arguments: List(String)) -> Command {
  // `--flag=X` を2語形に正規化し、既知フラグを位置によらず取り出す。
  let normalized = normalize_equals(arguments)
  let #(no_config, config) = take_config_flag(normalized, default_config_path())
  let #(rest, flags) = take_flags(no_config)
  case parse_limit(flags.limit_raw) {
    Error(message) -> Usage(message)
    Ok(limit) -> parse_command(rest, flags, config, limit)
  }
}

fn parse_command(
  rest: List(String),
  flags: Flags,
  config: String,
  limit: Int,
) -> Command {
  case rest {
    [] | ["run"] -> check_flags(flags, [], Run(config))
    ["validate"] -> check_flags(flags, [], Validate(config))
    ["status"] -> check_flags(flags, [], Status(config))
    ["dead", "list"] -> check_flags(flags, [], DeadList(config))
    ["dead", "retry", id] -> check_flags(flags, [], DeadRetry(config, id))
    ["dead", "delete", id] -> check_flags(flags, [], DeadDelete(config, id))
    ["events", "list"] ->
      check_flags(
        flags,
        ["--source", "--type", "--limit"],
        EventsList(
          config:,
          source: flags.source,
          event_type: flags.event_type,
          limit:,
        ),
      )
    ["events", "show", id] -> check_flags(flags, [], EventsShow(config, id))
    ["deliveries", "list"] ->
      case parse_status_flag(flags.status_raw) {
        Error(message) -> Usage(message)
        Ok(status) ->
          check_flags(
            flags,
            ["--status", "--destination", "--limit"],
            DeliveriesList(
              config:,
              status:,
              destination: flags.destination,
              limit:,
            ),
          )
      }
    ["deliveries", "show", id] ->
      check_flags(flags, [], DeliveriesShow(config, id))
    ["-h"] | ["--help"] | ["help"] -> Help
    other -> Usage("unknown arguments: " <> string.join(other, " "))
  }
}

fn normalize_equals(arguments: List(String)) -> List(String) {
  list.flat_map(arguments, fn(arg) {
    case expand_equals_flag(arg) {
      Some(pair) -> [pair.0, pair.1]
      None -> [arg]
    }
  })
}

/// `--flag=value` を `--flag` `value` に分割する。未知フラグはそのまま残し、
/// 後段の "unknown arguments" に落ちるようにする。
fn expand_equals_flag(arg: String) -> Option(#(String, String)) {
  let #(flag, value) = split_once(arg, "=")
  case flag, value {
    "--config", Some(value) -> Some(#("--config", value))
    "--source", Some(value) -> Some(#("--source", value))
    "--type", Some(value) -> Some(#("--type", value))
    "--destination", Some(value) -> Some(#("--destination", value))
    "--status", Some(value) -> Some(#("--status", value))
    "--limit", Some(value) -> Some(#("--limit", value))
    _, _ -> None
  }
}

fn split_once(text: String, separator: String) -> #(String, Option(String)) {
  case string.split_once(text, on: separator) {
    Ok(#(left, right)) -> #(left, Some(right))
    Error(_) -> #(text, None)
  }
}

fn take_config_flag(
  arguments: List(String),
  default: String,
) -> #(List(String), String) {
  case remove_config_flag(arguments, []) {
    #(rest, Some(path)) -> #(rest, path)
    #(rest, None) -> #(rest, default)
  }
}

fn remove_config_flag(
  arguments: List(String),
  kept: List(String),
) -> #(List(String), Option(String)) {
  case arguments {
    [] -> #(list.reverse(kept), None)
    ["--config", path, ..rest] -> #(
      list.append(list.reverse(kept), rest),
      Some(path),
    )
    [head, ..tail] -> remove_config_flag(tail, [head, ..kept])
  }
}

fn take_flags(arguments: List(String)) -> #(List(String), Flags) {
  remove_flags(arguments, [], empty_flags())
}

/// フラグと値を取り除き、位置引数だけを残す。同フラグが複数あれば最後が勝つ。
fn remove_flags(
  arguments: List(String),
  kept: List(String),
  flags: Flags,
) -> #(List(String), Flags) {
  case arguments {
    [] -> #(list.reverse(kept), flags)
    ["--source", value, ..rest] ->
      remove_flags(rest, kept, Flags(..flags, source: Some(value)))
    ["--type", value, ..rest] ->
      remove_flags(rest, kept, Flags(..flags, event_type: Some(value)))
    ["--destination", value, ..rest] ->
      remove_flags(rest, kept, Flags(..flags, destination: Some(value)))
    ["--status", value, ..rest] ->
      remove_flags(rest, kept, Flags(..flags, status_raw: Some(value)))
    ["--limit", value, ..rest] ->
      remove_flags(rest, kept, Flags(..flags, limit_raw: Some(value)))
    [head, ..tail] -> remove_flags(tail, [head, ..kept], flags)
  }
}

fn parse_limit(raw: Option(String)) -> Result(Int, String) {
  case raw {
    None -> Ok(default_limit)
    Some(text) ->
      case int.parse(text) {
        Error(_) -> Error("invalid --limit value: " <> text)
        Ok(value) ->
          case value {
            n if n < 1 -> Error("--limit must be at least 1")
            n if n > max_limit -> Ok(max_limit)
            n -> Ok(n)
          }
      }
  }
}

fn parse_status_flag(
  raw: Option(String),
) -> Result(Option(storage.DeliveryStatus), String) {
  case raw {
    None -> Ok(None)
    Some(value) ->
      case value {
        "pending" -> Ok(Some(storage.Pending))
        "delivering" -> Ok(Some(storage.Delivering))
        "retry_scheduled" -> Ok(Some(storage.RetryScheduled))
        "succeeded" -> Ok(Some(storage.Succeeded))
        "dead_letter" -> Ok(Some(storage.DeadLetter))
        _ ->
          Error(
            "invalid --status value: "
            <> value
            <> " (expected pending, delivering, retry_scheduled, succeeded or dead_letter)",
          )
      }
  }
}

/// コマンドが受け付けないフラグが付いていたら Usage エラーにする。
fn check_flags(
  flags: Flags,
  allowed: List(String),
  command: Command,
) -> Command {
  let used = [
    #("--source", present(flags.source)),
    #("--type", present(flags.event_type)),
    #("--destination", present(flags.destination)),
    #("--status", present(flags.status_raw)),
    #("--limit", present(flags.limit_raw)),
  ]
  case list.find(used, fn(pair) { pair.1 && !list.contains(allowed, pair.0) }) {
    Ok(pair) -> Usage("unexpected flag " <> pair.0 <> " for this command")
    Error(_) -> command
  }
}

fn present(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

pub fn help_text() -> String {
  string.join(
    [
      "vectum - lightweight self-hosted event router",
      "",
      "Usage:",
      "  vectum run [--config router.toml]",
      "  vectum validate [--config router.toml]",
      "  vectum status [--config router.toml]",
      "  vectum events list [--source S] [--type T] [--limit N] [--config router.toml]",
      "  vectum events show <event-id> [--config router.toml]",
      "  vectum deliveries list [--status pending|delivering|retry_scheduled|succeeded|dead_letter] [--destination D] [--limit N] [--config router.toml]",
      "  vectum deliveries show <delivery-id> [--config router.toml]",
      "  vectum dead list [--config router.toml]",
      "  vectum dead retry <delivery-id> [--config router.toml]",
      "  vectum dead delete <delivery-id> [--config router.toml]",
      "",
      "status / events / deliveries は読み取り専用で、状態を変更しない。",
      "--limit は既定 50、上限 1000。",
    ],
    "\n",
  )
}

/// 行を構造化データ(ここでは行のリスト)として組み立て、最後に TSV 化する。
/// 将来 JSON 出力を足すときはこの段階のデータをそのまま使える。
pub fn format_status(
  storage_path: String,
  snapshot: storage.StatusSnapshot,
  now_ms: Int,
) -> String {
  let counts = dict.from_list(snapshot.counts)
  let outstanding =
    list.fold(
      [storage.Pending, storage.Delivering, storage.RetryScheduled],
      0,
      fn(total, status) { total + count_of(counts, status) },
    )
  let oldest_lines = case snapshot.oldest_open_since_ms {
    None -> []
    Some(since) -> [
      "oldest_open_since_ms\t" <> int.to_string(since),
      "oldest_open_age_s\t" <> int.to_string({ now_ms - since } / 1000),
    ]
  }
  [
    "storage_path\t" <> storage_path,
    ..list.map(status_order(), fn(status) {
      storage.status_name(status)
      <> "\t"
      <> int.to_string(count_of(counts, status))
    })
  ]
  |> list.append(["pending_total\t" <> int.to_string(outstanding)])
  |> list.append(oldest_lines)
  |> string.join("\n")
}

fn count_of(
  counts: dict.Dict(storage.DeliveryStatus, Int),
  status: storage.DeliveryStatus,
) -> Int {
  case dict.get(counts, status) {
    Ok(count) -> count
    Error(_) -> 0
  }
}

fn status_order() -> List(storage.DeliveryStatus) {
  [
    storage.Pending,
    storage.Delivering,
    storage.RetryScheduled,
    storage.Succeeded,
    storage.DeadLetter,
  ]
}

pub fn format_dead(deliveries: List(Delivery)) -> String {
  case deliveries {
    [] -> "no dead-letter deliveries"
    _ ->
      [
        "id\tevent_id\tdestination\tattempts\terror",
        ..list.map(deliveries, format_row)
      ]
      |> string.join("\n")
  }
}

fn format_row(delivery: Delivery) -> String {
  string.join(
    [
      delivery.id,
      delivery.event_id,
      delivery.destination,
      int.to_string(delivery.attempts),
      option.unwrap(delivery.last_error, or: ""),
    ],
    "\t",
  )
}

pub fn format_events(events: List(event.Event)) -> String {
  case events {
    [] -> "no events"
    _ ->
      ["id\tsource\ttype\ttime\tpayload", ..list.map(events, format_event_row)]
      |> string.join("\n")
  }
}

fn format_event_row(event: event.Event) -> String {
  string.join(
    [
      event.id,
      event.source,
      event.event_type,
      event.timestamp,
      event.to_json_string(event.data),
    ],
    "\t",
  )
}

/// `events show`: 対象 Event 1 件と、それに紐づく Delivery 一覧。
pub fn format_event_show(
  event: event.Event,
  deliveries: List(Delivery),
) -> String {
  "event:\n"
  <> format_events([event])
  <> "\n\ndeliveries:\n"
  <> format_deliveries(deliveries)
}

pub fn format_deliveries(deliveries: List(Delivery)) -> String {
  case deliveries {
    [] -> "no deliveries"
    _ ->
      [
        "id\tevent_id\tdestination\tstatus\tattempts\tnext_attempt_at\tlast_attempt_at\tcreated_at\tupdated_at\tlast_error",
        ..list.map(deliveries, format_delivery_row)
      ]
      |> string.join("\n")
  }
}

fn format_delivery_row(delivery: Delivery) -> String {
  string.join(
    [
      delivery.id,
      delivery.event_id,
      delivery.destination,
      storage.status_name(delivery.status),
      int.to_string(delivery.attempts),
      int.to_string(delivery.next_attempt_at),
      optional_int(delivery.last_attempt_at),
      int.to_string(delivery.created_at),
      int.to_string(delivery.updated_at),
      option.unwrap(delivery.last_error, or: ""),
    ],
    "\t",
  )
}

fn optional_int(value: Option(Int)) -> String {
  case value {
    Some(n) -> int.to_string(n)
    None -> ""
  }
}

pub fn take_config(command: Command) -> Option(String) {
  case command {
    Run(path) | Validate(path) | DeadList(path) | Status(path) -> Some(path)
    DeadRetry(path, _) | DeadDelete(path, _) -> Some(path)
    EventsList(path, _, _, _) | EventsShow(path, _) -> Some(path)
    DeliveriesList(path, _, _, _) | DeliveriesShow(path, _) -> Some(path)
    Help | Usage(_) -> None
  }
}
