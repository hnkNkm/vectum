import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import vectum/clock
import vectum/config.{type Config}
import vectum/delivery.{type Outgoing, type SendResult}
import vectum/log
import vectum/metrics.{type Metrics}
import vectum/registry
import vectum/shutdown
import vectum/storage.{type Delivery, type Store}

/// body を実行し、例外(panic)があっても必ず after を呼んでから返す。
/// ワーカー枠の解放を panic でも保証するためのガード。
/// 戻り値は body が完走したかどうか。panic 時は False。
@external(erlang, "vectum_ffi", "run_guarded")
fn run_guarded(body: fn() -> a, after: fn() -> Nil) -> Bool

/// claim 間隔(ミリ秒)。
const poll_interval_ms = 200

/// reap チェック間隔(ミリ秒)。
const reap_interval_ms = 10_000

/// delivering が滞留と見なすまでの時間。
/// Destination の実効タイムアウト(個別指定、無ければ [delivery].timeout_ms)
/// の最大値の 2 倍、最低 10 秒。実行中の配送を誤って再開しないためのマージン。
pub fn stale_after_ms(config: Config) -> Int {
  let max_timeout =
    list.fold(config.destinations, config.delivery.timeout_ms, fn(acc, dest) {
      let config.HttpDestination(timeout_ms:, ..) = dest
      int.max(acc, option.unwrap(timeout_ms, config.delivery.timeout_ms))
    })
  int.max(max_timeout * 2, 10_000)
}

type State {
  State(
    config: Config,
    send: fn(Outgoing) -> SendResult,
    self: Subject(Msg),
    last_reap_ms: Int,
  )
}

pub type Msg {
  Tick
}

/// Supervisor 配下で dispatcher loop を起動する。
/// Storage / Metrics の参照は registry から毎 tick 読むため、
/// 先のプロセスが再起動しても自動的に新しい Subject を使う。
pub fn start_supervised(
  config: Config,
  send: fn(Outgoing) -> SendResult,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(2000, fn(subject) {
    process.send_after(subject, poll_interval_ms, Tick)
    actor.initialised(State(
      config:,
      send:,
      self: subject,
      last_reap_ms: clock.now_ms(),
    ))
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    Tick -> {
      case registry.get_store(), registry.get_metrics() {
        Ok(store), Ok(metrics) -> {
          case tick(state.config, store, metrics, state.send) {
            Ok(_) -> Nil
            Error(error) ->
              log.error([
                #("msg", "delivery_claim_failed"),
                #("error", error),
              ])
          }
          let state = reap_if_due(state, store, metrics)
          let _ = process.send_after(state.self, poll_interval_ms, Tick)
          actor.continue(state)
        }
        _, _ -> {
          let _ = process.send_after(state.self, poll_interval_ms, Tick)
          actor.continue(state)
        }
      }
    }
  }
}

fn reap_if_due(state: State, store: Store, metrics: Metrics) -> State {
  let now = clock.now_ms()
  case now - state.last_reap_ms >= reap_interval_ms {
    False -> state
    True -> {
      let cutoff = now - stale_after_ms(state.config)
      case storage.call_reap_stale(store, cutoff, now) {
        Ok(0) -> Nil
        Ok(count) -> {
          metrics.record_reaped(metrics, count)
          log.info([
            #("msg", "delivery_reaped"),
            #("count", int.to_string(count)),
            #("cutoff_ms", int.to_string(cutoff)),
          ])
        }
        Error(error) ->
          log.error([#("msg", "reap_failed"), #("error", string.inspect(error))])
      }
      State(..state, last_reap_ms: now)
    }
  }
}

pub fn tick(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
) -> Result(Int, String) {
  case shutdown.is_shutting_down() {
    True -> Ok(0)
    False -> {
      // concurrency は同時実行ワーカー数の上限。空き枠だけ claim する
      let active = shutdown.active_workers()
      let capacity = int.max(config.concurrency - active, 0)
      case capacity {
        0 -> Ok(0)
        _ ->
          storage.call_claim_due(store, clock.now_ms(), capacity)
          |> result.map_error(string.inspect)
          |> result.map(fn(due) {
            list.each(due, fn(item) {
              // claim と同時に枠を予約する。次の tick が読む前に確定させる
              shutdown.worker_started()
              process.spawn(fn() {
                run_guarded(
                  fn() {
                    let _ =
                      process_one_inner(config, store, metrics, send, item)
                    Nil
                  },
                  fn() { shutdown.worker_finished() },
                )
              })
              Nil
            })
            list.length(due)
          })
      }
    }
  }
}

pub fn process_one(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
  item: Delivery,
) -> Nil {
  shutdown.worker_started()
  // run_guarded は panic 時に False を返す。枠解放は FFI 側で保証される。
  let completed =
    run_guarded(
      fn() {
        let _ = process_one_inner(config, store, metrics, send, item)
        Nil
      },
      fn() { shutdown.worker_finished() },
    )
  case completed {
    True -> Nil
    False ->
      log.error([
        #("msg", "delivery_worker_panic"),
        #("delivery_id", item.id),
        #("destination", item.destination),
      ])
  }
}

fn process_one_inner(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
  item: Delivery,
) {
  metrics.record_attempt(metrics)
  // decide 前の取得・解決フェーズと decide 後の永続化フェーズを分離する。
  // 永続化の失敗を decide に戻すと誤遷移＋二重計数になるため、
  // persist 層の Error はログに留めて再スケジュールしない。
  let outcome = {
    use event <- result.try(
      storage.call_get_event(store, item.event_id)
      |> result.map_error(string.inspect),
    )
    use dest <- result.try(
      config.find_destination(config, item.destination)
      |> result.replace_error("unknown destination " <> item.destination),
    )
    let outgoing =
      delivery.build_outgoing(dest, event, config.delivery.timeout_ms)
    let started = clock.now_ms()
    let result = send(outgoing)
    let update =
      delivery.decide(
        config.delivery,
        item.attempts,
        result,
        clock.now_ms(),
        random_unit(),
      )
    Ok(#(event.id, update, clock.now_ms() - started))
  }
  case outcome {
    Ok(#(event_id, update, latency)) ->
      persist_or_log(store, metrics, item, event_id, update, latency)
    Error(reason) -> {
      log.error([
        #("msg", "delivery_failed"),
        #("delivery_id", item.id),
        #("error", reason),
      ])
      let update =
        delivery.decide(
          config.delivery,
          item.attempts,
          delivery.ConnectFailed(reason),
          clock.now_ms(),
          random_unit(),
        )
      persist_or_log(store, metrics, item, item.event_id, update, 0)
    }
  }
}

fn persist_or_log(
  store: Store,
  metrics: Metrics,
  item: Delivery,
  event_id: String,
  update: delivery.Update,
  latency: Int,
) -> Nil {
  case
    persist_update(
      store,
      metrics,
      item,
      event_id,
      update,
      clock.now_ms(),
      latency,
    )
  {
    Ok(_) -> Nil
    Error(error) ->
      log.error([
        #("msg", "delivery_persist_failed"),
        #("delivery_id", item.id),
        #("error", error),
      ])
  }
}

fn persist_update(
  store: Store,
  metrics: Metrics,
  item: Delivery,
  event_id: String,
  update: delivery.Update,
  now: Int,
  latency: Int,
) -> Result(Nil, String) {
  // mark 系は delivering の行にだけ効き、更新件数を返す。
  // 0 件 = reaper に奪取済みのため metrics/ログを出さず再送サイクルに委ねる。
  case update {
    delivery.Succeeded(attempts) -> {
      case
        storage.call_mark_success(store, item.id, attempts, now)
        |> result.map_error(string.inspect)
      {
        Ok(0) -> {
          log_stale(item, event_id, "success")
          Ok(Nil)
        }
        Ok(_) -> {
          metrics.record_success(metrics, latency)
          log.info([
            #("msg", "delivery_success"),
            #("event_id", event_id),
            #("delivery_id", item.id),
            #("destination", item.destination),
            #("attempt", int.to_string(attempts)),
            #("latency", int.to_string(latency)),
            #("result", "success"),
          ])
          Ok(Nil)
        }
        Error(error) -> Error(error)
      }
    }
    delivery.RetryScheduled(attempts, next, error) -> {
      case
        storage.call_mark_retry(store, item.id, attempts, next, error, now)
        |> result.map_error(string.inspect)
      {
        Ok(0) -> {
          log_stale(item, event_id, "retry")
          Ok(Nil)
        }
        Ok(_) -> {
          metrics.record_retry(metrics)
          log.info([
            #("msg", "delivery_retry"),
            #("event_id", event_id),
            #("delivery_id", item.id),
            #("destination", item.destination),
            #("attempt", int.to_string(attempts)),
            #("latency", int.to_string(latency)),
            #("result", "retry"),
            #("error", error),
          ])
          Ok(Nil)
        }
        Error(error) -> Error(error)
      }
    }
    delivery.DeadLettered(attempts, error) -> {
      case
        storage.call_mark_dead(store, item.id, attempts, error, now)
        |> result.map_error(string.inspect)
      {
        Ok(0) -> {
          log_stale(item, event_id, "dead_letter")
          Ok(Nil)
        }
        Ok(_) -> {
          metrics.record_dead(metrics)
          log.error([
            #("msg", "delivery_dead"),
            #("event_id", event_id),
            #("delivery_id", item.id),
            #("destination", item.destination),
            #("attempt", int.to_string(attempts)),
            #("latency", int.to_string(latency)),
            #("result", "dead_letter"),
            #("error", error),
          ])
          Ok(Nil)
        }
        Error(error) -> Error(error)
      }
    }
  }
}

fn log_stale(item: Delivery, event_id: String, outcome: String) -> Nil {
  log.info([
    #("msg", "delivery_stale"),
    #("event_id", event_id),
    #("delivery_id", item.id),
    #("destination", item.destination),
    #("outcome", outcome),
  ])
}

pub fn random_unit() -> Float {
  case crypto.strong_random_bytes(1) {
    <<n>> -> int.to_float(n) /. 255.0
    _ -> 0.5
  }
}
