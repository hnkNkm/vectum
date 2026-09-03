//// Supervisor が起動した Storage / Metrics actor の参照を共有する。
////
//// Supervisor 配下のプロセスは再起動で Subject が変わるため、
//// 固定の場所(persistent_term)に毎回上書きし、利用側は都度読み出す。

import gleam/erlang/process

import vectum/metrics.{type Metrics}
import vectum/storage.{type Store}

@external(erlang, "vectum_ffi", "registry_put_store")
pub fn put_store(store: Store) -> Nil

@external(erlang, "vectum_ffi", "registry_get_store")
pub fn get_store() -> Result(Store, Nil)

@external(erlang, "vectum_ffi", "registry_put_metrics")
pub fn put_metrics(metrics: Metrics) -> Nil

@external(erlang, "vectum_ffi", "registry_get_metrics")
pub fn get_metrics() -> Result(Metrics, Nil)

/// 死んだ Subject を再利用しないための読み出し。
/// owner が死んでいても persistent_term には古い参照が残るため、
/// 利用前に生存確認し、死んでいれば Error にする。
/// 呼出側は次 tick / 次 request で読み直し、再起動後の参照を拾う。
pub fn get_store_alive() -> Result(Store, Nil) {
  case get_store() {
    Error(_) -> Error(Nil)
    Ok(store) ->
      case process.subject_owner(store.subject) {
        Error(_) -> Error(Nil)
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(store)
            False -> Error(Nil)
          }
      }
  }
}

/// get_store_alive の Metrics 版。
pub fn get_metrics_alive() -> Result(Metrics, Nil) {
  case get_metrics() {
    Error(_) -> Error(Nil)
    Ok(metrics) ->
      case process.subject_owner(metrics.subject) {
        Error(_) -> Error(Nil)
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(metrics)
            False -> Error(Nil)
          }
      }
  }
}
