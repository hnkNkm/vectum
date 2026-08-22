import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import vectum/env
import vectum/storage.{type Delivery}

pub type Command {
  Run(config: String)
  Validate(config: String)
  DeadList(config: String)
  DeadRetry(config: String, id: String)
  DeadDelete(config: String, id: String)
  Help
  Usage(String)
}

pub fn default_config_path() -> String {
  case env.get("VECTUM_CONFIG") {
    Ok(path) -> path
    Error(_) -> "router.toml"
  }
}

pub fn parse(arguments: List(String)) -> Command {
  case arguments {
    [] | ["run"] -> Run(default_config_path())
    ["run", "--config", path] -> Run(path)
    ["validate"] -> Validate(default_config_path())
    ["validate", "--config", path] -> Validate(path)
    ["dead", "list"] -> DeadList(default_config_path())
    ["dead", "list", "--config", path] -> DeadList(path)
    ["dead", "retry", id] -> DeadRetry(default_config_path(), id)
    ["dead", "retry", id, "--config", path] -> DeadRetry(path, id)
    ["dead", "delete", id] -> DeadDelete(default_config_path(), id)
    ["dead", "delete", id, "--config", path] -> DeadDelete(path, id)
    ["-h"] | ["--help"] | ["help"] -> Help
    other -> Usage("unknown arguments: " <> string.join(other, " "))
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
      "  vectum dead list [--config router.toml]",
      "  vectum dead retry <delivery-id> [--config router.toml]",
      "  vectum dead delete <delivery-id> [--config router.toml]",
    ],
    "\n",
  )
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

pub fn take_config(command: Command) -> Option(String) {
  case command {
    Run(path) | Validate(path) | DeadList(path) -> Some(path)
    DeadRetry(path, _) | DeadDelete(path, _) -> Some(path)
    Help | Usage(_) -> None
  }
}
