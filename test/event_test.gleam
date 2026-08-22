import gleam/dict
import gleam/string
import vectum/event
import vectum/id

pub fn parse_object_and_nested_path_test() {
  let assert Ok(value) =
    event.parse_json(
      "{\"repository\":{\"name\":\"backend\"},\"amount\":10,\"ok\":true}",
    )
  let assert Ok(event.String("backend")) =
    event.get_path(value, "repository.name")
  let assert Ok(event.Int(10)) = event.get_path(value, "amount")
  let assert Ok(event.Bool(True)) = event.get_path(value, "ok")
  let assert Error(Nil) = event.get_path(value, "missing")
  let assert Error(Nil) = event.get_path(value, "repository.missing")
}

pub fn parse_array_null_and_float_test() {
  let assert Ok(value) = event.parse_json("{\"n\":null,\"xs\":[1,2.5,\"a\"]}")
  let assert Ok(event.Null) = event.get_path(value, "n")
  let assert Ok(event.Array([event.Int(1), event.Float(2.5), event.String("a")])) =
    event.get_path(value, "xs")
}

pub fn json_roundtrip_preserves_object_test() {
  let assert Ok(value) = event.parse_json("{\"a\":1,\"b\":\"x\"}")
  let encoded = event.to_json_string(value)
  let assert Ok(again) = event.parse_json(encoded)
  assert event.equal(value, again)
}

pub fn equal_coerces_int_and_float_test() {
  assert event.equal(event.Int(5), event.Float(5.0))
  assert !event.equal(event.Int(5), event.Float(5.1))
}

pub fn envelope_contains_required_fields_test() {
  let ev =
    event.Event(
      id: "id-1",
      source: "github",
      event_type: "push",
      timestamp: "2026-01-01T00:00:00.000Z",
      data: event.Object(dict.from_list([#("ref", event.String("main"))])),
      metadata: dict.from_list([#("x-github-event", "push")]),
    )
  let body = event.envelope_string(ev)
  assert string.contains(body, "\"id\":\"id-1\"")
  assert string.contains(body, "\"source\":\"github\"")
  assert string.contains(body, "\"type\":\"push\"")
  assert string.contains(body, "\"time\"")
  assert !string.contains(body, "\"timestamp\"")
  assert string.contains(body, "\"data\"")
  assert string.contains(body, "\"metadata\"")
}

pub fn event_id_is_uuid_v7_shaped_test() {
  let first = id.event_id()
  let second = id.event_id()
  assert first != second
  assert string.length(first) == 36
}
