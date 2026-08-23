import gleam/option.{None, Some}
import vectum/config.{
  type Config, Config, HttpDestination, ServerConfig, StorageConfig,
}
import vectum/dispatcher
import vectum/retry.{Policy}

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
