import gleam/erlang/process
import gleam/option.{Some}
import vectum/accept
import vectum/clock
import vectum/config
import vectum/delivery
import vectum/dispatcher
import vectum/id
import vectum/metrics
import vectum/storage

const toml = "
[storage]
path = \":memory:\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"audit\"
url = \"http://127.0.0.1:9/events\"

[[routes]]
name = \"all\"
source = \"internal\"
event = \"*\"
destinations = [\"audit\"]

[delivery]
max_attempts = 2
jitter = false
initial_backoff_ms = 1
max_backoff_ms = 1
"

fn cfg() -> config.Config {
  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  parsed
}

pub fn accept_then_successful_delivery_test() {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(metrics) = metrics.start()
  let assert Ok(accepted) =
    accept.normalize(
      cfg(),
      "internal",
      "application/json",
      [],
      "{\"type\":\"ping\",\"n\":1}",
      clock.now_rfc3339(),
      "evt-int",
    )
  let assert Ok([_queued]) =
    storage.call_accept(
      store,
      accepted.event,
      accepted.destinations,
      clock.now_ms(),
      [id.delivery_id()],
    )
  let assert Ok(1) = storage.call_pending_count(store)

  // mark_* は delivering の行にしか効かないため、実フローどおり claim する
  let assert Ok([claimed]) = storage.call_claim_due(store, clock.now_ms(), 10)
  dispatcher.process_one(
    cfg(),
    store,
    metrics,
    fn(_outgoing) { delivery.Status(200) },
    claimed,
  )
  process.sleep(20)
  let assert Ok(0) = storage.call_pending_count(store)
  let snap = metrics.snapshot(metrics)
  assert snap.deliveries_success == 1
}

pub fn failed_4xx_goes_to_dead_letter_test() {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(metrics) = metrics.start()
  let assert Ok(accepted) =
    accept.normalize(
      cfg(),
      "internal",
      "application/json",
      [],
      "{\"type\":\"ping\"}",
      clock.now_rfc3339(),
      "evt-dead",
    )
  let assert Ok([_queued]) =
    storage.call_accept(
      store,
      accepted.event,
      accepted.destinations,
      clock.now_ms(),
      ["dead-int"],
    )
  // mark_* は delivering の行にしか効かないため、実フローどおり claim する
  let assert Ok([queued]) = storage.call_claim_due(store, clock.now_ms(), 10)
  dispatcher.process_one(
    cfg(),
    store,
    metrics,
    fn(_outgoing) { delivery.Status(400) },
    queued,
  )
  process.sleep(20)
  let assert Ok([dead]) = storage.call_list_dead(store)
  assert dead.id == "dead-int"
  assert dead.last_error == Some("http 400")
}
