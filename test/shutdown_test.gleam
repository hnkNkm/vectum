import gleam/dict
import gleam/erlang/process
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
  let saved = reset_global_state()
  assert shutdown.is_shutting_down() == False
  restore_flag(saved)
}

pub fn persist_event_rejects_when_shutting_down_test() {
  let saved = reset_global_state()
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
  restore_flag(saved)
}

pub fn worker_counter_counts_up_and_down_test() {
  let saved = reset_global_state()
  let before = shutdown.active_workers()
  shutdown.worker_started()
  shutdown.worker_started()
  assert shutdown.active_workers() == before + 2
  shutdown.worker_finished()
  shutdown.worker_finished()
  assert shutdown.active_workers() == before
  restore_flag(saved)
}

pub fn grace_ms_defaults_and_parses_test() {
  let saved = reset_global_state()
  env_set("VECTUM_SHUTDOWN_GRACE_MS", "2500")
  assert shutdown.grace_ms() == 2500
  env_set("VECTUM_SHUTDOWN_GRACE_MS", "not-a-number")
  assert shutdown.grace_ms() == 10_000
  env_unset("VECTUM_SHUTDOWN_GRACE_MS")
  assert shutdown.grace_ms() == 10_000
  restore_flag(saved)
}

/// 停止フラグが立っている間は tick が claim を行わないこと。
pub fn tick_does_nothing_when_shutting_down_test() {
  let saved = reset_global_state()
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

  restore_flag(saved)
}

@external(erlang, "vectum_ffi", "set_env")
fn env_set(name: String, value: String) -> Nil

@external(erlang, "vectum_ffi", "unset_env")
fn env_unset(name: String) -> Nil

/// #68d: グローバル状態の隔離。停止フラグを保存・復元し、
/// grace 環境変数の残留を掃除する。
/// gleeunit に setup/teardown がないため各 test の先頭・末尾で呼ぶ。
/// カウンタは意図的に触らない: drain は in-flight の枠を奪い、
/// 遅延した解放が別 test に落ちるため。計数は baseline 相対で assert する。
fn reset_global_state() -> Bool {
  let flag = shutdown.is_shutting_down()
  shutdown.set_shutting_down(False)
  env_unset("VECTUM_SHUTDOWN_GRACE_MS")
  flag
}

fn restore_flag(saved: Bool) -> Nil {
  shutdown.set_shutting_down(saved)
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

/// #55: guard 内の受付は数えられ、完了で枠が返ること。
pub fn accept_guard_counts_inflight_and_releases_test() {
  let saved = reset_global_state()
  let base = shutdown.active_accepts()
  let entered = process.new_subject()
  let _child =
    process.spawn_unlinked(fn() {
      shutdown.with_accept_guard(fn() {
        process.send(entered, Nil)
        process.sleep(200)
      })
    })
  let assert Ok(Nil) = process.receive(entered, 2000)
  assert shutdown.active_accepts() == base + 1
  wait_until(fn() { shutdown.active_accepts() == base }, 3000)
  assert shutdown.active_accepts() == base
  restore_flag(saved)
}

/// #55: guard 内で panic しても枠は返り、例外は子に留まること。
pub fn accept_guard_releases_on_panic_test() {
  let saved = reset_global_state()
  let pid =
    process.spawn_unlinked(fn() {
      shutdown.with_accept_guard(fn() { panic as "boom" })
    })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  // 子の死を見届けても枠は漏れない
  let assert Ok(Nil) = process.selector_receive(selector, 2000)
  // 子の死を見届けた時点で枠は返っている
  wait_until(fn() { shutdown.active_accepts() == 0 }, 2000)
  restore_flag(saved)
}

pub fn admitted_accept_commits_during_shutdown_test() {
  let saved = reset_global_state()
  let base = shutdown.active_accepts()
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  shutdown.set_shutting_down(True)
  // guard 内相当:停止フラグが立っても受付済み分は 202 で commit する
  let response =
    shutdown.with_accept_guard(fn() {
      ingress.persist_admitted(
        cfg(),
        store,
        m,
        "internal",
        "application/json",
        [],
        "{\"type\":\"ping\"}",
      )
    })
  assert response.status == 202
  let assert Ok(1) = storage.call_pending_count(store)
  assert shutdown.active_accepts() == base
  restore_flag(saved)
}
