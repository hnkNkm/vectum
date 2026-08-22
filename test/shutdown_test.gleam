import gleam/dict
import vectum/clock
import vectum/config
import vectum/delivery
import vectum/dispatcher
import vectum/event.{Event}
import vectum/ingress
import vectum/metrics
import vectum/shutdown
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
"

fn cfg() -> config.Config {
  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  parsed
}

pub fn flag_is_false_by_default_test() {
  assert shutdown.is_shutting_down() == False
}

pub fn persist_event_rejects_when_shutting_down_test() {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  shutdown.set_shutting_down(True)

  let response =
    ingress.persist_event(
      cfg(),
      store,
      m,
      "internal",
      "application/json",
      [],
      "{\"type\":\"ping\"}",
    )
  assert response.status == 503

  shutdown.set_shutting_down(False)
  let response =
    ingress.persist_event(
      cfg(),
      store,
      m,
      "internal",
      "application/json",
      [],
      "{\"type\":\"ping\"}",
    )
  assert response.status == 202
}

pub fn worker_counter_counts_up_and_down_test() {
  let before = shutdown.active_workers()
  shutdown.worker_started()
  shutdown.worker_started()
  assert shutdown.active_workers() == before + 2
  shutdown.worker_finished()
  shutdown.worker_finished()
  assert shutdown.active_workers() == before
}

pub fn grace_ms_defaults_and_parses_test() {
  env_set("VECTUM_SHUTDOWN_GRACE_MS", "2500")
  assert shutdown.grace_ms() == 2500
  env_set("VECTUM_SHUTDOWN_GRACE_MS", "not-a-number")
  assert shutdown.grace_ms() == 10_000
  env_unset("VECTUM_SHUTDOWN_GRACE_MS")
  assert shutdown.grace_ms() == 10_000
}

/// 停止フラグが立っている間は tick が claim を行わないこと。
pub fn tick_does_nothing_when_shutting_down_test() {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let event =
    Event(
      id: "evt-shutdown-tick",
      source: "internal",
      event_type: "ping",
      timestamp: clock.now_rfc3339(),
      data: event.Null,
      metadata: dict.new(),
    )
  let assert Ok([_queued]) =
    storage.call_accept(store, event, ["audit"], clock.now_ms(), [
      "dlv-shutdown",
    ])
  shutdown.set_shutting_down(True)

  let assert Ok(0) =
    dispatcher.tick(cfg(), store, m, fn(_outgoing) { delivery.Status(200) })
  // tick 後も該当 Delivery は pending のまま(claim されていない)
  let assert Ok(1) = storage.call_pending_count(store)

  shutdown.set_shutting_down(False)
}

@external(erlang, "vectum_ffi", "set_env")
fn env_set(name: String, value: String) -> Nil

@external(erlang, "vectum_ffi", "unset_env")
fn env_unset(name: String) -> Nil
