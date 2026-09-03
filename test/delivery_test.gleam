import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

pub fn decide_internal_error_uses_backoff_then_dead_test() {
  let p = policy()
  let assert delivery.RetryScheduled(1, 1000, "unknown destination ci") =
    delivery.decide(
      p,
      0,
      delivery.ConnectFailed("unknown destination ci"),
      0,
      0.0,
    )
  let assert delivery.RetryScheduled(3, 4000, "db locked") =
    delivery.decide(p, 2, delivery.ConnectFailed("db locked"), 0, 0.0)
  let assert delivery.DeadLettered(8, "unknown destination ci") =
    delivery.decide(
      p,
      7,
      delivery.ConnectFailed("unknown destination ci"),
      0,
      0.0,
    )
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

/// #54-2: 接続失敗の詳細(DNS/TLS/posix 原因)を捨てずに残す。
pub fn connect_failed_preserves_detail_test() {
  let outgoing =
    delivery.Outgoing(
      url: "http://127.0.0.1:9/events",
      headers: [],
      body: "{}",
      timeout_ms: 2000,
    )
  let result = delivery.send_http(outgoing)
  case result {
    delivery.ConnectFailed(reason) -> {
      assert reason != "connection error"
      assert string.contains(reason, "FailedToConnect")
      let assert delivery.RetryScheduled(_, _, error) =
        delivery.decide(policy(), 0, result, 0, 0.0)
      assert string.contains(error, "FailedToConnect")
    }
    _ -> panic as "expected ConnectFailed for closed port"
  }
}
