import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import mist
import vectum/cli
import vectum/clock
import vectum/config.{ConfigError}
import vectum/delivery
import vectum/dispatcher
import vectum/env
import vectum/ingress
import vectum/log
import vectum/metrics
import vectum/storage

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
  let store = require_store(parsed.storage.path)
  let metrics = require_metrics()
  let _ = dispatcher.start(parsed, store, metrics, delivery.send_http)
  let assert Ok(_) =
    ingress.service(parsed, store, metrics)
    |> mist.new
    |> mist.bind(parsed.server.host)
    |> mist.port(parsed.server.port)
    |> mist.start
  log.info([
    #("msg", "listening"),
    #("host", parsed.server.host),
    #("port", int.to_string(parsed.server.port)),
    #("config", path),
  ])
  process.sleep_forever()
}

fn dead_list(path: String) -> Nil {
  let parsed = require_config(path)
  let store = require_store(parsed.storage.path)
  case storage.call_list_dead(store) {
    Ok(items) -> io.println(cli.format_dead(items))
    Error(error) ->
      fail("failed to list dead letters: " <> string.inspect(error))
  }
}

fn dead_retry(path: String, id: String) -> Nil {
  let parsed = require_config(path)
  let store = require_store(parsed.storage.path)
  case storage.call_retry_dead(store, id, clock.now_ms()) {
    Ok(_) -> io.println("requeued " <> id)
    Error(error) ->
      fail("failed to retry " <> id <> ": " <> string.inspect(error))
  }
}

fn dead_delete(path: String, id: String) -> Nil {
  let parsed = require_config(path)
  let store = require_store(parsed.storage.path)
  case storage.call_delete_dead(store, id) {
    Ok(_) -> io.println("deleted " <> id)
    Error(error) ->
      fail("failed to delete " <> id <> ": " <> string.inspect(error))
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

fn require_metrics() -> metrics.Metrics {
  case metrics.start() {
    Ok(m) -> m
    Error(error) -> fail("failed to start metrics: " <> error)
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
