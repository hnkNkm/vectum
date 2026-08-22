import gleam/dict
import gleam/list
import gleam/option.{Some}
import sqlight
import vectum/event
import vectum/storage

fn sample_event(id: String) -> event.Event {
  event.Event(
    id:,
    source: "github",
    event_type: "push",
    timestamp: "2026-01-01T00:00:00.000Z",
    data: event.Object(dict.from_list([#("ref", event.String("main"))])),
    metadata: dict.from_list([#("x-github-event", "push")]),
  )
}

fn with_db(run: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = storage.connect(":memory:")
  let assert Ok(Nil) = storage.migrate(conn)
  run(conn)
}

pub fn accept_persists_event_and_deduped_deliveries_test() {
  use conn <- with_db
  let ev = sample_event("evt-1")
  let assert Ok(deliveries) =
    storage.accept(conn, ev, ["ci", "audit", "ci"], 1000, ["d1", "d2", "d3"])
  assert list.map(deliveries, fn(d) { d.destination }) == ["ci", "audit"]
  let assert Ok(loaded) = storage.get_event(conn, "evt-1")
  assert loaded.id == "evt-1"
  assert loaded.event_type == "push"
  let assert Ok(event.String("main")) = event.get_path(loaded.data, "ref")
  let assert Ok(2) = storage.count_pending(conn)
}

pub fn claim_due_marks_delivering_and_skips_future_test() {
  use conn <- with_db
  let ev = sample_event("evt-2")
  let assert Ok(_) =
    storage.accept(conn, ev, ["ci", "audit"], 1000, ["d1", "d2"])
  let assert Ok([first]) = storage.claim_due(conn, 1000, 1)
  assert first.status == storage.Delivering
  let assert Ok([second]) = storage.claim_due(conn, 1000, 10)
  assert first.id != second.id
  let assert Ok([]) = storage.claim_due(conn, 1000, 10)
}

pub fn retry_then_dead_letter_and_cli_ops_test() {
  use conn <- with_db
  let ev = sample_event("evt-3")
  let assert Ok([delivery]) = storage.accept(conn, ev, ["ci"], 1000, ["dead-1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  assert claimed.id == delivery.id
  let assert Ok(Nil) =
    storage.mark_retry(conn, claimed.id, 1, 5000, "timeout", 1100)
  let assert Ok([]) = storage.claim_due(conn, 2000, 10)
  let assert Ok([again]) = storage.claim_due(conn, 5000, 10)
  let assert Ok(Nil) = storage.mark_dead(conn, again.id, 8, "boom", 6000)
  let assert Ok([dead]) = storage.list_dead(conn)
  assert dead.status == storage.DeadLetter
  assert dead.last_error == Some("boom")
  let assert Ok(0) = storage.count_pending(conn)

  let assert Ok(Nil) = storage.retry_dead(conn, dead.id, 7000)
  let assert Ok([]) = storage.list_dead(conn)
  let assert Ok([pending]) = storage.claim_due(conn, 7000, 1)
  assert pending.status == storage.Delivering

  let assert Ok(Nil) = storage.mark_dead(conn, pending.id, 8, "boom", 8000)
  let assert Ok(Nil) = storage.delete_dead(conn, pending.id)
  let assert Ok([]) = storage.list_dead(conn)
}

pub fn recover_resets_delivering_test() {
  use conn <- with_db
  let ev = sample_event("evt-4")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["r1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  assert claimed.status == storage.Delivering
  let assert Ok(_) = storage.recover(conn, 2000)
  let assert Ok([again]) = storage.claim_due(conn, 2000, 1)
  assert again.id == claimed.id
}

pub fn success_clears_pending_test() {
  use conn <- with_db
  let ev = sample_event("evt-5")
  let assert Ok(_) = storage.accept(conn, ev, ["ci"], 1000, ["s1"])
  let assert Ok([claimed]) = storage.claim_due(conn, 1000, 1)
  let assert Ok(Nil) = storage.mark_success(conn, claimed.id, 1, 1500)
  let assert Ok(0) = storage.count_pending(conn)
  let assert Ok([]) = storage.list_dead(conn)
}
