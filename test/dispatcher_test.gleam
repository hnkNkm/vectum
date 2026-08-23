import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import vectum/clock
import vectum/config.{
  type Config, Config, HttpDestination, ServerConfig, StorageConfig,
}
import vectum/delivery
import vectum/dispatcher
import vectum/event.{Event}
import vectum/metrics
import vectum/retry.{Policy}
import vectum/shutdown
import vectum/storage

fn base(timeout_ms: Int, destinations: List(config.Destination)) -> Config {
  Config(
    server: ServerConfig("127.0.0.1", 8080, 1024),
    storage: StorageConfig(":memory:"),
    sources: [],
    destinations:,
    routes: [],
    delivery: Policy(8, 1000, 60_000, timeout_ms, False),
    concurrency: 8,
  )
}

fn dest(name: String, timeout_ms: option.Option(Int)) -> config.Destination {
  HttpDestination(
    name:,
    url: "http://127.0.0.1:9/events",
    timeout_ms:,
    hmac_secret: None,
    hmac_header: "X-Vectum-Signature",
  )
}

pub fn stale_after_uses_global_timeout_when_dest_omits_it_test() {
  // 既定 10s → ×2 = 20s
  assert dispatcher.stale_after_ms(base(10_000, [])) == 20_000
  assert dispatcher.stale_after_ms(base(10_000, [dest("a", None)])) == 20_000
}

pub fn stale_after_floors_at_ten_seconds_test() {
  // 3s ×2 = 6s だが最低 10s
  assert dispatcher.stale_after_ms(base(3000, [])) == 10_000
}

pub fn stale_after_uses_longest_destination_timeout_test() {
  // dest 60s が最長 → ×2 = 120s。短い dest や省略は無視
  let config =
    base(10_000, [dest("fast", Some(5000)), dest("slow", Some(60_000))])
  assert dispatcher.stale_after_ms(config) == 120_000
}

// ---- concurrency 上限の検証 ----

const cap_toml = "
[storage]
path = \":memory:\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"a\"
url = \"http://127.0.0.1:9/a\"

[[destinations]]
name = \"b\"
url = \"http://127.0.0.1:9/b\"

[[destinations]]
name = \"c\"
url = \"http://127.0.0.1:9/c\"

[[destinations]]
name = \"d\"
url = \"http://127.0.0.1:9/d\"

[[routes]]
name = \"all\"
source = \"internal\"
event = \"*\"
destinations = [\"a\", \"b\", \"c\", \"d\"]

[delivery]
concurrency = 2
jitter = false
initial_backoff_ms = 1000
max_backoff_ms = 1000
"

fn slow_send(_outgoing: delivery.Outgoing) -> delivery.SendResult {
  process.sleep(150)
  delivery.Status(200)
}

pub fn tick_claims_only_free_capacity_test() {
  let baseline = shutdown.active_workers()
  let assert Ok(parsed) = config.parse_with(cap_toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let ev =
    Event(
      id: "evt-cap",
      source: "internal",
      event_type: "ping",
      timestamp: clock.now_rfc3339(),
      data: event.Null,
      metadata: dict.new(),
    )
  let assert Ok([_, _, _, _]) =
    storage.call_accept(store, ev, ["a", "b", "c", "d"], clock.now_ms(), [
      "cap-1",
      "cap-2",
      "cap-3",
      "cap-4",
    ])

  // 1 回目: 空き枠 2 だけ claim し、同時に枠を予約する
  let assert Ok(2) = dispatcher.tick(parsed, store, m, slow_send)
  assert shutdown.active_workers() == baseline + 2

  // 2 回目: 空き枠ゼロなので claim しない(ワーカーは増殖しない)
  let assert Ok(0) = dispatcher.tick(parsed, store, m, slow_send)
  assert shutdown.active_workers() == baseline + 2

  // 完了を待つと枠が解放され、残りが処理できる
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)
  let assert Ok(2) = dispatcher.tick(parsed, store, m, slow_send)
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)
  let assert Ok(0) = storage.call_pending_count(store)
}

fn wait_until(cond: fn() -> Bool, timeout_ms: Int) -> Nil {
  case cond() || timeout_ms <= 0 {
    True -> Nil
    False -> {
      process.sleep(25)
      wait_until(cond, timeout_ms - 25)
    }
  }
}
