import gleam/time/duration
import gleam/time/timestamp

/// Unix epoch milliseconds.
pub fn now_ms() -> Int {
  let #(seconds, nanos) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanos / 1_000_000
}

/// RFC3339 UTC timestamp for the Event envelope.
pub fn now_rfc3339() -> String {
  timestamp.system_time()
  |> timestamp.to_rfc3339(duration.seconds(0))
}

pub fn rfc3339_from_ms(millis: Int) -> String {
  timestamp.from_unix_seconds_and_nanoseconds(
    millis / 1000,
    { millis % 1000 } * 1_000_000,
  )
  |> timestamp.to_rfc3339(duration.seconds(0))
}
