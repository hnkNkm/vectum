import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/string
import mist
import sqlight
import vectum/cli
import vectum/clock
import vectum/config.{ConfigError}
import vectum/delivery
import vectum/env
import vectum/ingress
import vectum/log
import vectum/shutdown
import vectum/storage
import vectum/supervisor

pub fn run_command(arguments: List(String)) -> Nil {
  case cli.parse(arguments) {
    cli.Help -> io.println(cli.help_text())
    cli.Usage(message) -> {
      io.println_error(message)
      io.println_error(cli.help_text())
      env.halt(2)
    }
    cli.Validate(path) -> validate(path)
    cli.Run(path) -> run_server(path)
    cli.DeadList(path) -> dead_list(path)
    cli.DeadRetry(path, id) -> dead_retry(path, id)
    cli.DeadDelete(path, id) -> dead_delete(path, id)
    cli.Status(path) -> ops_status(path)
    cli.EventsList(path, source, event_type, limit) ->
      ops_events_list(path, source, event_type, limit)
    cli.EventsShow(path, id) -> ops_events_show(path, id)
    cli.DeliveriesList(path, status, destination, limit) ->
      ops_deliveries_list(path, status, destination, limit)
    cli.DeliveriesShow(path, id) -> ops_deliveries_show(path, id)
  }
}

pub fn validate(path: String) -> Nil {
  case config.load(path) {
    Ok(parsed) -> {
      io.println(
        "ok: "
        <> path
        <> " ("
        <> int.to_string(list.length(parsed.sources))
        <> " sources, "
        <> int.to_string(list.length(parsed.destinations))
        <> " destinations, "
        <> int.to_string(list.length(parsed.routes))
        <> " routes)",
      )
    }
    Error(ConfigError(messages)) -> {
      print_errors(path, messages)
      env.halt(1)
    }
  }
}

pub fn run_server(path: String) -> Nil {
  let parsed = require_config(path)
  shutdown.init()
  // listen 前にハンドラを入れる。起動直後の SIGTERM も graceful に扱う
  shutdown.install_handler(shutdown.run_shutdown_sequence)
  // 全件復旧はプロセス起動時に一度だけ。actor 再起動では reaper に委ねる
  case storage.open_and_recover(parsed.storage.path, clock.now_ms()) {
    Ok(_) -> Nil
    Error(error) ->
      fail("failed to open storage " <> parsed.storage.path <> ": " <> error)
  }
  case supervisor.start_tree(parsed, delivery.send_http) {
    Ok(_) -> Nil
    Error(error) -> fail("failed to start services: " <> error)
  }
  case
    ingress.service_from_registry(parsed)
    |> mist.new
    |> mist.bind(parsed.server.host)
    |> mist.port(parsed.server.port)
    |> mist.start
  {
    Ok(_) -> Nil
    Error(error) ->
      fail(
        "failed to bind "
        <> parsed.server.host
        <> ":"
        <> int.to_string(parsed.server.port)
        <> ": "
        <> string.inspect(error),
      )
  }
  log.info([
    #("msg", "listening"),
    #("host", parsed.server.host),
    #("port", int.to_string(parsed.server.port)),
    #("config", path),
  ])
  process.sleep_forever()
}

fn dead_list(path: String) -> Nil {
  let store = require_dead_store(path)
  case storage.call_list_dead(store) {
    Ok(items) -> io.println(cli.format_dead(items))
    Error(error) ->
      fail("failed to list dead letters: " <> string.inspect(error))
  }
}

fn dead_retry(path: String, id: String) -> Nil {
  let store = require_dead_store(path)
  case storage.call_retry_dead(store, id, clock.now_ms()) {
    Ok(0) -> fail("no dead-letter delivery with id " <> id)
    Ok(_) -> io.println("requeued " <> id)
    Error(error) ->
      fail("failed to retry " <> id <> ": " <> string.inspect(error))
  }
}

fn dead_delete(path: String, id: String) -> Nil {
  let store = require_dead_store(path)
  case storage.call_delete_dead(store, id) {
    Ok(0) -> fail("no dead-letter delivery with id " <> id)
    Ok(_) -> io.println("deleted " <> id)
    Error(error) ->
      fail("failed to delete " <> id <> ": " <> string.inspect(error))
  }
}

/// dead-letter / read-only 運用系は `[storage] path` のみ読む。secret 検証エラー時も操作できる。
fn require_dead_store(path: String) -> storage.Store {
  require_store(ops_storage_path(path))
}

/// 運用系コマンドの storage path 解決。失敗時は設定エラーを出して終了する。
fn ops_storage_path(path: String) -> String {
  case config.load_storage_path(path) {
    Ok(storage_path) -> storage_path
    Error(ConfigError(messages)) -> {
      print_errors(path, messages)
      env.halt(1)
      panic as "unreachable"
    }
  }
}

fn ops_status(path: String) -> Nil {
  let storage_path = ops_storage_path(path)
  let store = require_store(storage_path)
  case storage.call_status_snapshot(store) {
    Ok(snapshot) ->
      io.println(cli.format_status(storage_path, snapshot, clock.now_ms()))
    Error(error) -> fail("failed to read status: " <> string.inspect(error))
  }
}

fn ops_events_list(
  path: String,
  source: Option(String),
  event_type: Option(String),
  limit: Int,
) -> Nil {
  let store = require_dead_store(path)
  case storage.call_list_events(store, source, event_type, limit) {
    Ok(events) -> io.println(cli.format_events(events))
    Error(error) -> fail("failed to list events: " <> string.inspect(error))
  }
}

fn ops_events_show(path: String, id: String) -> Nil {
  let store = require_dead_store(path)
  case storage.call_get_event(store, id) {
    Ok(event) ->
      case storage.call_list_event_deliveries(store, id) {
        Ok(deliveries) -> io.println(cli.format_event_show(event, deliveries))
        Error(error) ->
          fail(
            "failed to load deliveries for event "
            <> id
            <> ": "
            <> string.inspect(error),
          )
      }
    Error(sqlight.SqlightError(sqlight.Notfound, _, _)) ->
      fail("no event with id " <> id)
    Error(error) ->
      fail("failed to load event " <> id <> ": " <> string.inspect(error))
  }
}

fn ops_deliveries_list(
  path: String,
  status: Option(storage.DeliveryStatus),
  destination: Option(String),
  limit: Int,
) -> Nil {
  let store = require_dead_store(path)
  case storage.call_list_deliveries(store, status, destination, limit) {
    Ok(deliveries) -> io.println(cli.format_deliveries(deliveries))
    Error(error) -> fail("failed to list deliveries: " <> string.inspect(error))
  }
}

fn ops_deliveries_show(path: String, id: String) -> Nil {
  let store = require_dead_store(path)
  case storage.call_get_delivery(store, id) {
    Ok(delivery) -> io.println(cli.format_deliveries([delivery]))
    Error(sqlight.SqlightError(sqlight.Notfound, _, _)) ->
      fail("no delivery with id " <> id)
    Error(error) ->
      fail("failed to load delivery " <> id <> ": " <> string.inspect(error))
  }
}

fn require_config(path: String) -> config.Config {
  case config.load(path) {
    Ok(parsed) -> parsed
    Error(ConfigError(messages)) -> {
      print_errors(path, messages)
      env.halt(1)
      panic as "unreachable"
    }
  }
}

fn require_store(path: String) -> storage.Store {
  case storage.start(path) {
    Ok(store) -> store
    Error(error) -> fail("failed to open storage " <> path <> ": " <> error)
  }
}

fn print_errors(path: String, messages: List(String)) -> Nil {
  io.println_error("invalid config: " <> path)
  list.each(messages, fn(message) { io.println_error("- " <> message) })
}

fn fail(message: String) -> a {
  io.println_error(message)
  env.halt(1)
  panic as "unreachable"
}
