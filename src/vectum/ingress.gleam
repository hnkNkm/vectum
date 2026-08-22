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
import vectum/storage.{type Store}

pub fn service(
  config: Config,
  store: Store,
  metrics: Metrics,
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(req) { handle_connection(config, store, metrics, req) }
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

fn list_ids(destinations: List(String)) -> List(String) {
  list.map(destinations, fn(_) { id.delivery_id() })
}

fn ready(store: Store) -> Response(ResponseData) {
  case storage.call_ping(store) {
    Ok(_) -> text(200, "ready\n")
    Error(_) -> text(503, "not ready\n")
  }
}

fn metrics_response(store: Store, metrics: Metrics) -> Response(ResponseData) {
  let pending = case storage.call_pending_count(store) {
    Ok(n) -> n
    Error(_) -> 0
  }
  let body = metrics.prometheus(metrics.snapshot(metrics), pending)
  response.new(200)
  |> response.set_header("content-type", "text/plain; version=0.0.4")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
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
