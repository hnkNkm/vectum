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
  // `--config=X` を2語形に正規化し、`--config <path>` を位置によらず
  // 1回だけ取り出す。残りでサブコマンドを判定する。
  let #(rest, config) =
    take_config_flag(normalize_equals(arguments), default_config_path())
  case rest {
    [] | ["run"] -> Run(config)
    ["validate"] -> Validate(config)
    ["dead", "list"] -> DeadList(config)
    ["dead", "retry", id] -> DeadRetry(config, id)
    ["dead", "delete", id] -> DeadDelete(config, id)
    ["-h"] | ["--help"] | ["help"] -> Help
    other -> Usage("unknown arguments: " <> string.join(other, " "))
  }
}

fn normalize_equals(arguments: List(String)) -> List(String) {
  list.flat_map(arguments, fn(arg) {
    case string.starts_with(arg, "--config=") {
      True -> ["--config", string.drop_start(arg, 9)]
      False -> [arg]
    }
  })
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
