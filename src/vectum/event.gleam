import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Transport-independent JSON value used for payloads and filter comparison.
pub type EventValue {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(EventValue))
  Object(Dict(String, EventValue))
}

pub type Event {
  Event(
    id: String,
    source: String,
    event_type: String,
    timestamp: String,
    data: EventValue,
    metadata: Dict(String, String),
  )
}

pub fn decoder() -> decode.Decoder(EventValue) {
  decode.recursive(fn() {
    decode.one_of(null_decoder(), [
      decode.map(decode.bool, Bool),
      decode.map(decode.int, Int),
      decode.map(decode.float, Float),
      decode.map(decode.string, String),
      decode.map(decode.list(decoder()), Array),
      decode.map(decode.dict(decode.string, decoder()), Object),
    ])
  })
}

fn null_decoder() -> decode.Decoder(EventValue) {
  decode.new_primitive_decoder("Null", fn(data) {
    case dynamic.classify(data) {
      "Nil" -> Ok(Null)
      _ -> Error(Null)
    }
  })
}

pub fn parse_json(raw: String) -> Result(EventValue, json.DecodeError) {
  json.parse(from: raw, using: decoder())
}

pub fn to_json(value: EventValue) -> json.Json {
  case value {
    Null -> json.null()
    Bool(flag) -> json.bool(flag)
    Int(n) -> json.int(n)
    Float(n) -> json.float(n)
    String(text) -> json.string(text)
    Array(items) -> json.preprocessed_array(list.map(items, to_json))
    Object(fields) ->
      json.object(
        dict.to_list(fields)
        |> list.map(fn(pair) { #(pair.0, to_json(pair.1)) }),
      )
  }
}

pub fn to_json_string(value: EventValue) -> String {
  json.to_string(to_json(value))
}

/// Dot-separated object walk. Arrays are not indexed in v0.1.
pub fn get_path(value: EventValue, path: String) -> Result(EventValue, Nil) {
  case string.split(path, on: ".") {
    [""] -> Error(Nil)
    segments -> walk(value, segments)
  }
}

fn walk(value: EventValue, segments: List(String)) -> Result(EventValue, Nil) {
  case segments {
    [] -> Ok(value)
    [key, ..rest] ->
      case value {
        Object(fields) -> {
          use next <- result.try(dict.get(fields, key))
          walk(next, rest)
        }
        _ -> Error(Nil)
      }
  }
}

pub fn envelope_json(event: Event) -> json.Json {
  json.object([
    #("id", json.string(event.id)),
    #("source", json.string(event.source)),
    #("type", json.string(event.event_type)),
    #("timestamp", json.string(event.timestamp)),
    #("data", to_json(event.data)),
    #(
      "metadata",
      json.object(
        dict.to_list(event.metadata)
        |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
      ),
    ),
  ])
}

pub fn envelope_string(event: Event) -> String {
  json.to_string(envelope_json(event))
}

pub fn equal(left: EventValue, right: EventValue) -> Bool {
  case left, right {
    Null, Null -> True
    Bool(a), Bool(b) -> a == b
    String(a), String(b) -> a == b
    Int(a), Int(b) -> a == b
    Float(a), Float(b) -> a == b
    Int(a), Float(b) -> int.to_float(a) == b
    Float(a), Int(b) -> a == int.to_float(b)
    Array(a), Array(b) ->
      list.length(a) == list.length(b)
      && list.all(list.zip(a, b), fn(pair) { equal(pair.0, pair.1) })
    Object(a), Object(b) ->
      dict.size(a) == dict.size(b)
      && dict.fold(a, True, fn(ok, key, value) {
        case dict.get(b, key) {
          Ok(other) -> ok && equal(value, other)
          Error(_) -> False
        }
      })
    _, _ -> False
  }
}
