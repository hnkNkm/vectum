import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import vectum/accept
import vectum/clock
import vectum/config.{type Config}
import vectum/id
import vectum/log
import vectum/metrics.{type Metrics}
import vectum/registry
import vectum/shutdown
import vectum/storage.{type Store}

pub fn service(
  config: Config,
  store: Store,
  metrics: Metrics,
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(req) { handle_connection(config, store, metrics, req) }
}

/// Supervisor 配下で使うサービス。registry から都度参照を読むため、
/// actor の再起動で Subject が変わっても追従する。
pub fn service_from_registry(
  config: Config,
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(req) {
    case registry.get_store_alive(), registry.get_metrics_alive() {
      Ok(store), Ok(metrics) -> handle_connection(config, store, metrics, req)
      _, _ ->
        response.new(503)
        |> response.set_header("content-type", "text/plain")
        |> response.set_body(mist.Bytes(bytes_tree.from_string("starting\n")))
    }
  }
}

pub fn handle_connection(
  config: Config,
  store: Store,
  metrics: Metrics,
  req: Request(Connection),
) -> Response(ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, ["health"] -> text(200, "ok\n")
    http.Get, ["ready"] -> ready(store)
    http.Get, ["metrics"] -> metrics_response(store, metrics)
    http.Post, ["events", source] ->
      post_event(config, store, metrics, source, req)
    _, _ -> json_error(404, "not found")
  }
}

fn post_event(
  config: Config,
  store: Store,
  metrics: Metrics,
  source: String,
  req: Request(Connection),
) -> Response(ResponseData) {
  case shutdown.is_shutting_down() {
    True -> json_error(503, "shutting down")
    False -> read_and_persist(config, store, metrics, source, req)
  }
}

fn read_and_persist(
  config: Config,
  store: Store,
  metrics: Metrics,
  source: String,
  req: Request(Connection),
) -> Response(ResponseData) {
  case is_chunked(req.headers) {
    True -> {
      metrics.record_rejected(metrics)
      json_error(413, "payload size exceeded")
    }
    False -> read_body_with_limit(config, store, metrics, source, req)
  }
}

/// mist 6 の read_body は Content-Length 無しを 0 とみなし、
/// chunked ボディを上限なしで読む。巨大 chunked でメモリ枯渇するため、
/// chunked を含む Transfer-Encoding は読み取り前に 413 で拒否する。
fn is_chunked(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    string.lowercase(header.0) == "transfer-encoding"
    && string.contains(string.lowercase(header.1), "chunked")
  })
}

fn read_body_with_limit(
  config: Config,
  store: Store,
  metrics: Metrics,
  source: String,
  req: Request(Connection),
) -> Response(ResponseData) {
  case mist.read_body(req, config.server.max_body_bytes) {
    Error(mist.ExcessBody) -> {
      metrics.record_rejected(metrics)
      json_error(413, "payload size exceeded")
    }
    Error(mist.MalformedBody) -> {
      metrics.record_rejected(metrics)
      json_error(400, "invalid json")
    }
    Ok(req) ->
      case bit_array.to_string(req.body) {
        Error(_) -> {
          metrics.record_rejected(metrics)
          json_error(400, "invalid json")
        }
        Ok(body) -> {
          let content_type =
            request.get_header(req, "content-type")
            |> result.unwrap("")
          persist_event(
            config,
            store,
            metrics,
            source,
            content_type,
            req.headers,
            body,
          )
        }
      }
  }
}

pub fn persist_event(
  config: Config,
  store: Store,
  metrics: Metrics,
  source: String,
  content_type: String,
  headers: List(#(String, String)),
  body: String,
) -> Response(ResponseData) {
  case shutdown.is_shutting_down() {
    True -> json_error(503, "shutting down")
    False ->
      case
        accept.normalize(
          config,
          source,
          content_type,
          headers,
          body,
          clock.now_rfc3339(),
          id.event_id(),
        )
      {
        Error(accept.Reject(status, reason)) -> {
          metrics.record_rejected(metrics)
          log.error([
            #("msg", "event_rejected"),
            #("source", source),
            #("reason", reason),
            #("status", int.to_string(status)),
          ])
          json_error(status, reason)
        }
        Ok(accept.Accepted(event:, destinations:)) -> {
          let ids = list_ids(destinations)
          case
            storage.call_accept(store, event, destinations, clock.now_ms(), ids)
          {
            Error(error) -> {
              metrics.record_rejected(metrics)
              log.error([
                #("msg", "persist_failed"),
                #("source", source),
                #("error", string.inspect(error)),
              ])
              json_error(500, "persist failed")
            }
            Ok(deliveries) -> {
              metrics.record_received(metrics)
              log.info([
                #("msg", "event_accepted"),
                #("event_id", event.id),
                #("source", event.source),
                #("event_type", event.event_type),
                #("deliveries", int.to_string(list.length(deliveries))),
              ])
              accepted(event.id, list.length(deliveries))
            }
          }
        }
      }
  }
}

fn list_ids(destinations: List(String)) -> List(String) {
  list.map(destinations, fn(_) { id.delivery_id() })
}

fn ready(store: Store) -> Response(ResponseData) {
  let db_ok = case shutdown.is_shutting_down() {
    True -> False
    False -> storage.call_ping(store) |> result.is_ok
  }
  case db_ok {
    True -> text(200, "ready\n")
    False -> text(503, "not ready\n")
  }
}

fn metrics_response(store: Store, metrics: Metrics) -> Response(ResponseData) {
  // Storage / Metrics のどちらかが死んでいてもハンドラは落とさず 503。
  // Dispatcher と同じく次 request で復帰する。
  case storage.call_pending_count(store), metrics.snapshot(metrics) {
    Ok(pending), Ok(snap) -> {
      let body = metrics.prometheus(snap, pending)
      response.new(200)
      |> response.set_header("content-type", "text/plain; version=0.0.4")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    }
    _, _ -> text(503, "unavailable\n")
  }
}

fn accepted(event_id: String, deliveries: Int) -> Response(ResponseData) {
  let body =
    json.object([
      #("id", json.string(event_id)),
      #("accepted", json.bool(True)),
      #("deliveries", json.int(deliveries)),
    ])
    |> json.to_string
  response.new(202)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_error(status: Int, reason: String) -> Response(ResponseData) {
  let body =
    json.object([
      #("error", json.string(reason)),
      #("accepted", json.bool(False)),
    ])
    |> json.to_string
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn text(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
