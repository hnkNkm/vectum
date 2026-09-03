import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import vectum/clock
import vectum/config.{
  type Config, Config, HttpDestination, ServerConfig, StorageConfig,
}
import vectum/delivery
import vectum/registry

import vectum/dispatcher
import vectum/event.{type Event, Event}
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

/// ワーカーが panic しても枠は解放され、次 tick で claimできること(#26)。
/// ワーカーが panic しても枠は解放され、以降も claim を続けられること(#26)。
pub fn panicked_worker_releases_slot_test() {
  let baseline = shutdown.active_workers()
  let assert Ok(parsed) = config.parse_with(cap_toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let ev =
    Event(
      id: "evt-panic",
      source: "internal",
      event_type: "ping",
      timestamp: clock.now_rfc3339(),
      data: event.Null,
      metadata: dict.new(),
    )
  let assert Ok([_, _, _]) =
    storage.call_accept(store, ev, ["a", "b", "c"], clock.now_ms(), [
      "panic-1", "panic-2", "panic-3",
    ])

  // send が panic するワーカーでも枠を解放する(guarded 実行)
  let assert Ok(2) =
    dispatcher.tick(parsed, store, m, fn(_outgoing) { panic as "boom" })
  assert shutdown.active_workers() == baseline + 2
  wait_until(fn() { shutdown.active_workers() == baseline }, 2000)

  // 枠が戻っているため、残り 1 件を通常どおり処理できる
  let assert Ok(1) =
    dispatcher.tick(parsed, store, m, fn(_outgoing) { delivery.Status(200) })
  wait_until(
    fn() {
      case metrics.snapshot(m) {
        Ok(snap) -> snap.deliveries_success == 1
        Error(_) -> False
      }
    },
    3000,
  )
  assert shutdown.active_workers() == baseline
}

fn evt(id: String) -> Event {
  Event(
    id:,
    source: "internal",
    event_type: "ping",
    timestamp: clock.now_rfc3339(),
    data: event.Null,
    metadata: dict.new(),
  )
}

/// #43: Dispatcher が死んでも in-flight ワーカーは道連れにせず、枠を返すこと。
/// 再起動後の Dispatcher 相当が空き枠で claim できること。
pub fn dispatcher_death_does_not_leak_slots_test() {
  let baseline = shutdown.active_workers()
  let assert Ok(parsed) = config.parse_with(cap_toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let assert Ok([_, _]) =
    storage.call_accept(store, evt("evt-restart"), ["a", "b"], clock.now_ms(), [
      "rs-1", "rs-2",
    ])

  // Dispatcher 役の別プロセスが tick 直後に死ぬ想定。
  // 自プロセスと link しないよう unlinked で立てる。
  let dispatcher_pid =
    process.spawn_unlinked(fn() {
      let assert Ok(2) = dispatcher.tick(parsed, store, m, slow_send)
      process.sleep_forever()
    })
  wait_until(fn() { shutdown.active_workers() == baseline + 2 }, 2000)
  assert shutdown.active_workers() == baseline + 2
  process.kill(dispatcher_pid)

  // ワーカーは生き残り、完了時に枠を返す。漏れがあれば戻らない
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)
  assert shutdown.active_workers() == baseline
  let assert Ok(0) = storage.call_pending_count(store)

  // 再起動後の claim が空き枠で動くこと
  let assert Ok([_]) =
    storage.call_accept(store, evt("evt-restart-2"), ["c"], clock.now_ms(), [
      "rs-3",
    ])
  let assert Ok(1) =
    dispatcher.tick(parsed, store, m, fn(_outgoing) { delivery.Status(200) })
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)
  let assert Ok(0) = storage.call_pending_count(store)
}

/// #43: send 失敗(retry 応答)でも枠は解放され、集計は通常どおり付くこと。
pub fn failed_send_releases_slot_test() {
  let baseline = shutdown.active_workers()
  let assert Ok(parsed) = config.parse_with(cap_toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let assert Ok([_]) =
    storage.call_accept(store, evt("evt-fail"), ["a"], clock.now_ms(), [
      "fail-1",
    ])

  let assert Ok(1) =
    dispatcher.tick(parsed, store, m, fn(_outgoing) { delivery.Status(500) })
  assert shutdown.active_workers() == baseline + 1
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)

  // retry 予定として残り、未到来のためすぐには再 claim されない
  let assert Ok(1) = storage.call_pending_count(store)
  let assert Ok([]) = storage.call_claim_due(store, clock.now_ms(), 10)
  let assert Ok(snap) = metrics.snapshot(m)
  assert snap.deliveries_retry == 1
}

/// #44: Storage 無応答でも tick は Error を返すだけで呼出側は死なず、
/// 復旧後の Store で claim を再開できること。
pub fn storage_outage_tick_fails_safe_and_resumes_test() {
  let baseline = shutdown.active_workers()
  let assert Ok(parsed) = config.parse_with(cap_toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let assert Ok([_]) =
    storage.call_accept(store, evt("evt-outage"), ["a"], clock.now_ms(), [
      "out-1",
    ])

  // Storage actor を殺す。自プロセスとの link を先に外す。
  let assert Ok(pid) = process.subject_owner(store.subject)
  process.unlink(pid)
  process.kill(pid)
  wait_until(fn() { process.is_alive(pid) == False }, 2000)
  assert process.is_alive(pid) == False

  // 死んだ Store への tick / 呼び出しは Error を返すだけで panic しない
  let assert Error(_) = dispatcher.tick(parsed, store, m, slow_send)
  assert shutdown.active_workers() == baseline
  let assert Error(_) = storage.call_ping(store)

  // 復旧後の Store では claim が再開できること
  let assert Ok(recovered) = storage.start(":memory:")
  let assert Ok([_]) =
    storage.call_accept(recovered, evt("evt-outage-2"), ["b"], clock.now_ms(), [
      "out-2",
    ])
  let assert Ok(1) =
    dispatcher.tick(parsed, recovered, m, fn(_outgoing) { delivery.Status(200) })
  wait_until(fn() { shutdown.active_workers() == baseline }, 3000)
  let assert Ok(0) = storage.call_pending_count(recovered)
}

/// #44: registry は死んだ参照を返さず、再起動後の参照に追従すること。
pub fn registry_does_not_reuse_dead_subjects_test() {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  registry.put_store(store)
  registry.put_metrics(m)
  let assert Ok(_) = registry.get_store_alive()
  let assert Ok(_) = registry.get_metrics_alive()

  let assert Ok(pid) = process.subject_owner(store.subject)
  process.unlink(pid)
  process.kill(pid)
  wait_until(
    fn() {
      case registry.get_store_alive() {
        Ok(_) -> False
        Error(_) -> True
      }
    },
    2000,
  )
  let assert Error(Nil) = registry.get_store_alive()
  // Metrics は生きているためそのまま使える
  let assert Ok(_) = registry.get_metrics_alive()

  // 復旧後の参照を登録すれば追従する
  let assert Ok(recovered) = storage.start(":memory:")
  registry.put_store(recovered)
  let assert Ok(live) = registry.get_store_alive()
  let assert Ok(_) = storage.call_ping(live)
}

/// #44: Metrics 死でも snapshot は Error を返し、呼出側は落ちないこと。
/// (/metrics ハンドラはこの Error を 503 に変換する)
pub fn dead_metrics_snapshot_returns_error_test() {
  let assert Ok(m) = metrics.start()
  let assert Ok(_) = metrics.snapshot(m)
  let assert Ok(pid) = process.subject_owner(m.subject)
  process.unlink(pid)
  process.kill(pid)
  wait_until(fn() { process.is_alive(pid) == False }, 2000)
  let assert Error(Nil) = metrics.snapshot(m)
}
