import gleam/option.{Some}
import gleam/string
import vectum/cli
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
