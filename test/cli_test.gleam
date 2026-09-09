import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import vectum/cli
import vectum/event
import vectum/storage.{Delivery}

pub fn parse_run_and_validate_test() {
  let assert cli.Run("router.toml") = cli.parse([])
  let assert cli.Run("x.toml") = cli.parse(["run", "--config", "x.toml"])
  let assert cli.Validate("x.toml") =
    cli.parse(["validate", "--config", "x.toml"])
  let assert cli.Help = cli.parse(["--help"])
}

pub fn parse_dead_letter_commands_test() {
  let assert cli.DeadList("db.toml") =
    cli.parse(["dead", "list", "--config", "db.toml"])
  let assert cli.DeadRetry("router.toml", "d1") =
    cli.parse(["dead", "retry", "d1"])
  let assert cli.DeadDelete("c.toml", "d2") =
    cli.parse(["dead", "delete", "d2", "--config", "c.toml"])
}

pub fn parse_config_equals_and_leading_flag_test() {
  let assert cli.Run("x.toml") = cli.parse(["run", "--config=x.toml"])
  let assert cli.Run("x.toml") = cli.parse(["--config", "x.toml", "run"])
  let assert cli.Validate("v.toml") = cli.parse(["--config=v.toml", "validate"])
  let assert cli.DeadRetry("c.toml", "d2") =
    cli.parse(["dead", "retry", "--config", "c.toml", "d2"])
  let assert cli.DeadList("db.toml") =
    cli.parse(["dead", "list", "--config=db.toml"])
}

pub fn format_dead_table_test() {
  assert cli.format_dead([]) == "no dead-letter deliveries"
  let row =
    Delivery(
      id: "d1",
      event_id: "e1",
      destination: "audit",
      status: storage.DeadLetter,
      attempts: 8,
      next_attempt_at: 1,
      last_attempt_at: Some(1),
      last_error: Some("timeout"),
      created_at: 1,
      updated_at: 1,
    )
  let text = cli.format_dead([row])
  assert string.contains(text, "d1")
  assert string.contains(text, "timeout")
}

/// --- #31: read-only ops CLI ---
pub fn parse_read_only_commands_test() {
  let assert cli.Status("db.toml") =
    cli.parse(["status", "--config", "db.toml"])
  let assert cli.Status("x.toml") = cli.parse(["--config=x.toml", "status"])

  let assert cli.EventsList("router.toml", None, None, 50) =
    cli.parse(["events", "list"])
  let assert cli.EventsList("c.toml", Some("github"), Some("push"), 7) =
    cli.parse([
      "events",
      "list",
      "--config",
      "c.toml",
      "--source",
      "github",
      "--type",
      "push",
      "--limit",
      "7",
    ])
  let assert cli.EventsList("c.toml", Some("github"), None, 3) =
    cli.parse([
      "events",
      "list",
      "--source=github",
      "--limit=3",
      "--config=c.toml",
    ])
  let assert cli.EventsShow("router.toml", "evt-1") =
    cli.parse(["events", "show", "evt-1"])

  let assert cli.DeliveriesList("router.toml", None, None, 50) =
    cli.parse(["deliveries", "list"])
  let assert cli.DeliveriesList(
    "db.toml",
    Some(storage.RetryScheduled),
    Some("ci"),
    100,
  ) =
    cli.parse([
      "deliveries",
      "list",
      "--config",
      "db.toml",
      "--status",
      "retry_scheduled",
      "--destination",
      "ci",
      "--limit",
      "100",
    ])
  let assert cli.DeliveriesShow("c.toml", "del-9") =
    cli.parse(["deliveries", "show", "del-9", "--config", "c.toml"])
}

pub fn parse_all_delivery_status_values_test() {
  let assert cli.DeliveriesList("router.toml", Some(storage.Pending), None, 50) =
    cli.parse(["deliveries", "list", "--status", "pending"])
  let assert cli.DeliveriesList(
    "router.toml",
    Some(storage.Delivering),
    None,
    50,
  ) = cli.parse(["deliveries", "list", "--status", "delivering"])
  let assert cli.DeliveriesList(
    "router.toml",
    Some(storage.RetryScheduled),
    None,
    50,
  ) = cli.parse(["deliveries", "list", "--status", "retry_scheduled"])
  let assert cli.DeliveriesList(
    "router.toml",
    Some(storage.Succeeded),
    None,
    50,
  ) = cli.parse(["deliveries", "list", "--status", "succeeded"])
  let assert cli.DeliveriesList(
    "router.toml",
    Some(storage.DeadLetter),
    None,
    50,
  ) = cli.parse(["deliveries", "list", "--status", "dead_letter"])
}

pub fn parse_limit_bounds_test() {
  // 既定 50・上限 1000 に clamp
  let assert cli.EventsList("router.toml", None, None, 50) =
    cli.parse(["events", "list"])
  let assert cli.EventsList("router.toml", None, None, 1000) =
    cli.parse(["events", "list", "--limit", "5000"])
  let assert cli.EventsList("router.toml", None, None, 1000) =
    cli.parse(["events", "list", "--limit", "1000"])
  let assert cli.EventsList("router.toml", None, None, 1) =
    cli.parse(["events", "list", "--limit", "1"])
  // 範囲外・非整数は Usage
  let assert cli.Usage(_) = cli.parse(["events", "list", "--limit", "0"])
  let assert cli.Usage(_) = cli.parse(["events", "list", "--limit", "-3"])
  let assert cli.Usage(_) = cli.parse(["events", "list", "--limit", "abc"])
}

pub fn parse_rejects_invalid_status_and_unexpected_flags_test() {
  let assert cli.Usage(_) =
    cli.parse(["deliveries", "list", "--status", "bogus"])
  // show / status / run は絞り込みフラグを受け付けない
  let assert cli.Usage(_) =
    cli.parse(["events", "show", "e1", "--source", "github"])
  let assert cli.Usage(_) = cli.parse(["status", "--limit", "5"])
  let assert cli.Usage(_) =
    cli.parse(["deliveries", "show", "d1", "--destination", "ci"])
  let assert cli.Usage(_) = cli.parse(["run", "--source", "x"])
  // list でも無関係なフラグは拒否
  let assert cli.Usage(_) = cli.parse(["events", "list", "--destination", "ci"])
  let assert cli.Usage(_) =
    cli.parse(["deliveries", "list", "--source", "github"])
}

pub fn help_text_lists_read_only_commands_test() {
  let text = cli.help_text()
  assert string.contains(text, "vectum status")
  assert string.contains(text, "vectum events list")
  assert string.contains(text, "vectum events show")
  assert string.contains(text, "vectum deliveries list")
  assert string.contains(text, "vectum deliveries show")
  assert string.contains(text, "--limit")
}

fn sample_event(id: String) {
  event.Event(
    id:,
    source: "github",
    event_type: "push",
    timestamp: "2026-01-01T00:00:00.000Z",
    data: event.Object(dict.from_list([#("ref", event.String("main"))])),
    metadata: dict.new(),
  )
}

fn sample_delivery(id: String) {
  Delivery(
    id:,
    event_id: "e1",
    destination: "ci",
    status: storage.RetryScheduled,
    attempts: 3,
    next_attempt_at: 5000,
    last_attempt_at: Some(4000),
    last_error: Some("timeout"),
    created_at: 1000,
    updated_at: 4000,
  )
}

pub fn format_events_output_test() {
  assert cli.format_events([]) == "no events"
  let text = cli.format_events([sample_event("evt-1")])
  assert string.contains(text, "id\tsource\ttype\ttime\tpayload")
  assert string.contains(text, "evt-1")
  assert string.contains(text, "github")
  assert string.contains(text, "push")
  assert string.contains(text, "main")
}

pub fn format_deliveries_output_test() {
  assert cli.format_deliveries([]) == "no deliveries"
  let text = cli.format_deliveries([sample_delivery("del-1")])
  assert string.contains(text, "del-1")
  assert string.contains(text, "retry_scheduled")
  assert string.contains(text, "timeout")
  assert string.contains(text, "e1")
  // last_attempt_at / last_error の列がある
  assert string.contains(text, "last_attempt_at")
  assert string.contains(text, "last_error")
}

pub fn format_event_show_contains_event_and_deliveries_test() {
  let text =
    cli.format_event_show(sample_event("evt-1"), [sample_delivery("del-1")])
  assert string.contains(text, "event:")
  assert string.contains(text, "deliveries:")
  assert string.contains(text, "evt-1")
  assert string.contains(text, "del-1")
}

pub fn format_status_output_test() {
  let snapshot =
    storage.StatusSnapshot(
      counts: [#(storage.Pending, 2), #(storage.Succeeded, 5)],
      oldest_open_since_ms: Some(123_456),
    )
  let text = cli.format_status("/data/router.db", snapshot, 163_456)
  assert string.contains(text, "storage_path\t/data/router.db")
  // 5 status すべて行がある(0 も明示)
  assert string.contains(text, "pending\t2")
  assert string.contains(text, "delivering\t0")
  assert string.contains(text, "retry_scheduled\t0")
  assert string.contains(text, "succeeded\t5")
  assert string.contains(text, "dead_letter\t0")
  // 未完了合計は pending + delivering + retry_scheduled
  assert string.contains(text, "pending_total\t2")
  // age = (163456 - 123456) / 1000 = 40 秒
  assert string.contains(text, "oldest_open_since_ms\t123456")
  assert string.contains(text, "oldest_open_age_s\t40")

  let empty = storage.StatusSnapshot(counts: [], oldest_open_since_ms: None)
  let text2 = cli.format_status("p.db", empty, 200_000)
  assert string.contains(text2, "oldest_open_since_ms") == False
  assert string.contains(text2, "oldest_open_age_s") == False
}
