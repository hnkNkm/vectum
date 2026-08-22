//// Supervisor が起動した Storage / Metrics actor の参照を共有する。
////
//// Supervisor 配下のプロセスは再起動で Subject が変わるため、
//// 固定の場所(persistent_term)に毎回上書きし、利用側は都度読み出す。

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
