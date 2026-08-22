//// RootSupervisor。Storage / Metrics / Dispatcher を one_for_one で監視する。
////
//// 各子プロセスは permanent で再起動される。Storage / Metrics は起動後に
//// registry へ自分の参照を登録し、Ingress / Dispatcher は registry から
//// 毎回読み出すため、再起動で Subject が変わっても追従できる。

import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import vectum/config.{type Config}
import vectum/delivery.{type Outgoing, type SendResult}
import vectum/dispatcher
import vectum/metrics
import vectum/registry
import vectum/storage

/// 監視木を起動する。失敗時はエラーメッセージを返す。
pub fn start_tree(
  config: Config,
  send: fn(Outgoing) -> SendResult,
) -> Result(Nil, String) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.restart_tolerance(intensity: 10, period: 5)
  |> static_supervisor.add(metrics_child())
  |> static_supervisor.add(storage_child(config.storage.path))
  |> static_supervisor.add(dispatcher_child(config, send))
  |> static_supervisor.start
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn metrics_child() {
  supervision.worker(fn() {
    case metrics.start_supervised() {
      Ok(started) -> {
        registry.put_metrics(started.data)
        Ok(started)
      }
      Error(e) -> Error(e)
    }
  })
}

fn storage_child(path: String) {
  supervision.worker(fn() {
    case storage.start_supervised(path) {
      Ok(started) -> {
        registry.put_store(started.data)
        Ok(started)
      }
      Error(e) -> Error(e)
    }
  })
}

fn dispatcher_child(config: Config, send: fn(Outgoing) -> SendResult) {
  supervision.worker(fn() { dispatcher.start_supervised(config, send) })
}
