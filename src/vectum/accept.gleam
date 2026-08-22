import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import vectum/config.{type Config, type Source}
import vectum/event.{type Event, Event}
import vectum/hmac
import vectum/id
import vectum/route

pub type Reject {
  Reject(status: Int, reason: String)
}

pub type Accepted {
  Accepted(event: Event, destinations: List(String))
}

pub fn normalize(
  config: Config,
  source_name: String,
  content_type: String,
  headers: List(#(String, String)),
  body: String,
  timestamp: String,
  event_id: String,
) -> Result(Accepted, Reject) {
  use source <- result.try(require_source(config, source_name))
  use _ <- result.try(require_json_content_type(content_type))
  use _ <- result.try(verify_hmac(source, headers, body))
  use data <- result.try(parse_body(body))
  use event_type <- result.try(extract_event_type(source, headers, data))
  let event =
    Event(
      id: event_id,
      source: source.name,
      event_type:,
      timestamp:,
      data:,
      metadata: collect_metadata(headers, source.hmac_header),
    )
  let destinations = route.select_destinations(config.routes, event)
  Ok(Accepted(event:, destinations:))
}

pub fn normalize_new(
  config: Config,
  source_name: String,
  content_type: String,
  headers: List(#(String, String)),
  body: String,
  timestamp: String,
) -> Result(Accepted, Reject) {
  normalize(
    config,
    source_name,
    content_type,
    headers,
    body,
    timestamp,
    id.event_id(),
  )
}

fn require_source(config: Config, name: String) -> Result(Source, Reject) {
  config.find_source(config, name)
  |> result.replace_error(Reject(404, "unknown source"))
}

fn require_json_content_type(content_type: String) -> Result(Nil, Reject) {
  let lowered = string.lowercase(content_type)
  case string.contains(lowered, "application/json") {
    True -> Ok(Nil)
    False -> Error(Reject(415, "invalid content-type"))
  }
}

fn parse_body(body: String) -> Result(event.EventValue, Reject) {
  event.parse_json(body)
  |> result.replace_error(Reject(400, "invalid json"))
}

fn verify_hmac(
  source: Source,
  headers: List(#(String, String)),
  body: String,
) -> Result(Nil, Reject) {
  case source.hmac_secret {
    None -> Ok(Nil)
    Some(secret) ->
      case header_value(headers, source.hmac_header) {
        Error(_) -> Error(Reject(401, "hmac failure"))
        Ok(provided) ->
          case hmac.verify_string(secret, body, provided) {
            True -> Ok(Nil)
            False -> Error(Reject(401, "hmac failure"))
          }
      }
  }
}

fn extract_event_type(
  source: Source,
  headers: List(#(String, String)),
  data: event.EventValue,
) -> Result(String, Reject) {
  let from_header = case source.type_from_header {
    Some(name) -> header_value(headers, name)
    None -> Error(Nil)
  }
  let from_json = case source.type_from_json {
    Some(path) ->
      case event.get_path(data, path) {
        Ok(event.String(value)) -> Ok(value)
        _ -> Error(Nil)
      }
    None -> Error(Nil)
  }
  let from_fixed = case source.type_fixed {
    Some(value) -> Ok(value)
    None -> Error(Nil)
  }
  from_header
  |> result.or(from_json)
  |> result.or(from_fixed)
  |> result.replace_error(Reject(400, "missing event type"))
}

fn collect_metadata(
  headers: List(#(String, String)),
  hmac_header: String,
) -> dict.Dict(String, String) {
  let skip = [
    "authorization",
    "cookie",
    string.lowercase(hmac_header),
  ]
  headers
  |> list.filter(fn(pair) { !list.contains(skip, string.lowercase(pair.0)) })
  |> list.map(fn(pair) { #(string.lowercase(pair.0), pair.1) })
  |> dict.from_list
}

pub fn header_value(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  let wanted = string.lowercase(name)
  headers
  |> list.find(fn(pair) { string.lowercase(pair.0) == wanted })
  |> result.map(fn(pair) { pair.1 })
}
