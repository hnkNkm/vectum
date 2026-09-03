//// #50: corrupt event rows must not dispatch as success.
//// Dispatcher routes the get_event Error through the existing
//// internal-error retry path and records the error.

import gleam/dynamic/decode
import gleam/option.{None}
import simplifile
import sqlight
import vectum/config
import vectum/delivery
import vectum/dispatcher
import vectum/metrics
import vectum/storage

const toml = "
[storage]
path = \":memory:\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"a\"
url = \"http://127.0.0.1:9/a\"

[[routes]]
name = \"all\"
source = \"internal\"
event = \"*\"
destinations = [\"a\"]

[delivery]
concurrency = 2
jitter = false
initial_backoff_ms = 1000
max_backoff_ms = 1000
"

fn remove_db(path: String) -> Nil {
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  let _ = simplifile.delete(path <> "-journal")
  Nil
}

pub fn corrupt_event_row_goes_to_retry_not_success_test() {
  let path = "tmp/vectum-corrupt-test.db"
  let _ = simplifile.create_directory("tmp")
  remove_db(path)

  // accept() を迂回して壊れた payload 行と pending 配送を直接挿入する
  let assert Ok(setup) = storage.connect(path)
  let assert Ok(_) = storage.migrate(setup)
  let assert Ok(_) =
    sqlight.query(
      "insert into events
       (id, source, event_type, timestamp, received_at, payload, metadata)
       values
       ('evt-corr', 'internal', 'ping', '2026-01-01T00:00:00.000Z', 1000,
        '{broken', '{}')",
      on: setup,
      with: [],
      expecting: decode.success(Nil),
    )
  let assert Ok(_) =
    sqlight.query(
      "insert into deliveries
       (id, event_id, destination, status, attempts,
        next_attempt_at, last_attempt_at, last_error, created_at, updated_at)
       values
       ('corr-1', 'evt-corr', 'a', 'pending', 0, 1000, null, null, 1000, 1000)",
      on: setup,
      with: [],
      expecting: decode.success(Nil),
    )
  let assert Ok(_) = sqlight.close(setup)

  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(path)
  let assert Ok(m) = metrics.start()
  let assert Ok([claimed]) = storage.call_claim_due(store, 9999, 10)

  // 壊れた行は dispatch 前に失敗するため send は呼ばれない
  dispatcher.process_one(
    parsed,
    store,
    m,
    fn(_outgoing: delivery.Outgoing) -> delivery.SendResult {
      panic as "must not send corrupt event"
    },
    claimed,
  )

  let assert Ok(snap) = metrics.snapshot(m)
  assert snap.deliveries_success == 0

  // 既存の内部エラー経路で retry_scheduled になり、原因が残る
  let assert Ok(direct) = storage.connect(path)
  let assert Ok([#(status, last_error)]) =
    sqlight.query(
      "select status, last_error from deliveries where id = 'corr-1'",
      on: direct,
      with: [],
      expecting: {
        use status <- decode.field(0, decode.string)
        use last_error <- decode.field(1, decode.optional(decode.string))
        decode.success(#(status, last_error))
      },
    )
  assert status == "retry_scheduled"
  assert last_error != None
  let assert Ok(_) = sqlight.close(direct)
  remove_db(path)
}
