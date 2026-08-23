//// Supervisor 木の起動と障害復旧の検証。

import gleam/erlang/process
import vectum/config
import vectum/delivery
import vectum/metrics
import vectum/registry
import vectum/storage
import vectum/supervisor

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

fn stub_send(_outgoing: delivery.Outgoing) -> delivery.SendResult {
  delivery.Status(200)
}

/// Storage actor を強制 kill しても、Supervisor が再起動し、
/// registry 経由で新しい参照が手に入ること。
pub fn supervisor_restarts_storage_after_kill_test() {
  let assert Ok(_) = supervisor.start_tree(cfg(), stub_send)
  let assert Ok(store) = registry.get_store()
  let assert Ok(metrics_handle) = registry.get_metrics()

  let assert Ok(pid) = process.subject_owner(store.subject)
  let _ = metrics_handle
  process.kill(pid)
  process.sleep(500)

  // 再起動後の参照が取得でき、応答すること
  let assert Ok(restarted) = registry.get_store()
  let assert Ok(_) = storage.call_ping(restarted)

  // かつ別プロセスとして動いていること
  let assert Ok(new_pid) = process.subject_owner(restarted.subject)
  assert new_pid != pid

  let assert Ok(_) = storage.call_ping(restarted)
}

/// Metrics actor も同様に再起動されること。単独実行でも動くよう
/// 自分で監視木を起動する。
pub fn supervisor_restarts_metrics_after_kill_test() {
  let assert Ok(_) = supervisor.start_tree(cfg(), stub_send)
  let assert Ok(m) = registry.get_metrics()
  let assert Ok(pid) = process.subject_owner(m.subject)
  process.kill(pid)
  process.sleep(500)

  let assert Ok(restarted) = registry.get_metrics()
  // snapshot が応答すれば再起動済み(カウンタはリセットされる)
  let _ = metrics.snapshot(restarted)
  let assert Ok(new_pid) = process.subject_owner(restarted.subject)
  assert new_pid != pid
}
