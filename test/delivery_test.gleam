import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import vectum/config.{HttpDestination}
import vectum/delivery
import vectum/event
import vectum/retry.{type Policy, Policy}

fn ev() -> event.Event {
  event.Event(
    id: "evt",
    source: "github",
    event_type: "push",
    timestamp: "t",
    data: event.Object(dict.new()),
    metadata: dict.new(),
  )
}

fn policy() -> Policy {
  Policy(8, 1000, 60_000, 10_000, False)
}

pub fn outgoing_includes_idempotency_headers_test() {
  let dest =
    HttpDestination(
      name: "audit",
      url: "http://127.0.0.1:9/events",
      timeout_ms: Some(1234),
      hmac_secret: Some("out"),
      hmac_header: "X-Vectum-Signature",
    )
  let outgoing = delivery.build_outgoing(dest, ev(), 9999)
  assert outgoing.url == "http://127.0.0.1:9/events"
  assert outgoing.timeout_ms == 1234
  assert list.key_find(outgoing.headers, "x-event-id") == Ok("evt")
  assert list.key_find(outgoing.headers, "idempotency-key") == Ok("evt")
  assert list.key_find(outgoing.headers, "content-type")
    == Ok("application/json")
  let assert Ok(_) = list.key_find(outgoing.headers, "x-vectum-signature")
}

pub fn decide_success_retry_and_dead_test() {
  let p = policy()
  let assert delivery.Succeeded(1) =
    delivery.decide(p, 0, delivery.Status(204), 0, 0.0)
  let assert delivery.RetryScheduled(1, 1000, "http 500") =
    delivery.decide(p, 0, delivery.Status(500), 0, 0.0)
  let assert delivery.DeadLettered(1, "http 400") =
    delivery.decide(p, 0, delivery.Status(400), 0, 0.0)
  let assert delivery.DeadLettered(8, "timeout") =
    delivery.decide(p, 7, delivery.TimedOut, 0, 0.0)
}

pub fn default_timeout_used_when_destination_omits_it_test() {
  let dest =
    HttpDestination(
      name: "audit",
      url: "http://127.0.0.1:9/events",
      timeout_ms: None,
      hmac_secret: None,
      hmac_header: "X-Vectum-Signature",
    )
  assert delivery.build_outgoing(dest, ev(), 4321).timeout_ms == 4321
}
