//// Graceful shutdown の調整。
////
//// - 受付停止フラグ(persistent_term):Ingress と dispatcher が参照する
//// - 実行中配送ワーカーのカウンタ:終了時に完了を待つために使う
//// - SIGTERM / SIGINT ハンドラのインストール
////
//// ワーカーが panic してカウンタを減らし忘れた場合でも、猶予時間で打ち切り
//// になるため終了は止まらない。

import gleam/erlang/process
import gleam/int
import vectum/env
import vectum/log

@external(erlang, "vectum_ffi", "shutdown_flag_get")
pub fn is_shutting_down() -> Bool

@external(erlang, "vectum_ffi", "shutdown_flag_set")
pub fn set_shutting_down(value: Bool) -> Nil

@external(erlang, "vectum_ffi", "worker_started")
pub fn worker_started() -> Nil

@external(erlang, "vectum_ffi", "worker_finished")
pub fn worker_finished() -> Nil

@external(erlang, "vectum_ffi", "active_worker_count")
pub fn active_workers() -> Int

/// カウンタの参照を起動時に一本化しておく。
/// 初回アクセスが複数プロセスから同時に起こると参照が分裂し得るため、
/// run_server 冒頭で必ず呼ぶ。
pub fn init() -> Nil {
  let _ = active_workers()
  Nil
}

/// SIGTERM / SIGINT を捕捉して `on_shutdown` を呼ぶハンドラをインストールする。
@external(erlang, "vectum_ffi", "install_shutdown_handler")
pub fn install_handler(on_shutdown: fn() -> Nil) -> Nil

const default_grace_ms = 10_000

@external(erlang, "vectum_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// 猶予時間(ミリ秒)。環境変数 `VECTUM_SHUTDOWN_GRACE_MS`、既定 10 秒。
/// 不正値 (非数値・負数) は警告ログを出して既定に倒す。
/// `0` は drain なし (即時 halt) を意味する。
pub fn grace_ms() -> Int {
  case env.get("VECTUM_SHUTDOWN_GRACE_MS") {
    Ok(raw) ->
      case int.parse(raw) {
        Ok(ms) if ms >= 0 -> ms
        _ -> {
          log.info([
            #("msg", "invalid_shutdown_grace"),
            #("value", raw),
            #("fallback_ms", int.to_string(default_grace_ms)),
          ])
          default_grace_ms
        }
      }
    Error(_) -> default_grace_ms
  }
}

/// シグナル受信時の停止シーケンス。
///
/// 1. 受付停止フラグを立てる(Ingress は 503、dispatcher は新規 claim を止める)
/// 2. 実行中ワーカーの完了を猶予時間内で待つ
/// 3. プロセス全体を正常終了させる
pub fn run_shutdown_sequence() -> Nil {
  set_shutting_down(True)
  log.info([
    #("msg", "shutdown_started"),
    #("grace_ms", int.to_string(grace_ms())),
    #("active_workers", int.to_string(active_workers())),
  ])
  // 締切は monotonic 基準。wall-clock (NTP ステップ) の影響を受けない。
  wait_for_workers(monotonic_ms() + grace_ms())
  log.info([#("msg", "shutdown_complete")])
  env.halt(0)
}

fn wait_for_workers(deadline_ms: Int) -> Nil {
  case active_workers() <= 0 || monotonic_ms() >= deadline_ms {
    True -> Nil
    False -> {
      process.sleep(50)
      wait_for_workers(deadline_ms)
    }
  }
}
