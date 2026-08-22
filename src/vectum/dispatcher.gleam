import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import vectum/clock
import vectum/config.{type Config}
import vectum/delivery.{type Outgoing, type SendResult}
import vectum/log
import vectum/metrics.{type Metrics}
import vectum/shutdown
import vectum/storage.{type Delivery, type Store}

pub fn start(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
) -> process.Pid {
  process.spawn(fn() { loop(config, store, metrics, send) })
}

fn loop(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
) -> Nil {
  let _ = tick(config, store, metrics, send)
  process.sleep(200)
  loop(config, store, metrics, send)
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
      storage.call_claim_due(store, clock.now_ms(), config.concurrency)
      |> result.map_error(string.inspect)
      |> result.map(fn(due) {
        list.each(due, fn(item) {
          process.spawn(fn() { process_one(config, store, metrics, send, item) })
          Nil
        })
        list.length(due)
      })
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
  process_one_inner(config, store, metrics, send, item)
  shutdown.worker_finished()
  Nil
}

/// 注意: panic 時は worker_finished が呼ばれずカウンタが漏れるが、
/// shutdown 側は猶予時間で打ち切るため終了は止まらない。
fn process_one_inner(
  config: Config,
  store: Store,
  metrics: Metrics,
  send: fn(Outgoing) -> SendResult,
  item: Delivery,
) {
  metrics.record_attempt(metrics)
  let now = clock.now_ms()
  case
    {
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
      let latency = clock.now_ms() - started
      persist_update(store, metrics, item, event.id, update, now, latency)
    }
  {
    Ok(_) -> Nil
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
          now,
          random_unit(),
        )
      let _ =
        persist_update(store, metrics, item, item.event_id, update, now, 0)
      Nil
    }
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
  case update {
    delivery.Succeeded(attempts) -> {
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
      storage.call_mark_success(store, item.id, attempts, now)
      |> result.map_error(string.inspect)
    }
    delivery.RetryScheduled(attempts, next, error) -> {
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
      storage.call_mark_retry(store, item.id, attempts, next, error, now)
      |> result.map_error(string.inspect)
    }
    delivery.DeadLettered(attempts, error) -> {
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
      storage.call_mark_dead(store, item.id, attempts, error, now)
      |> result.map_error(string.inspect)
    }
  }
}

pub fn random_unit() -> Float {
  case crypto.strong_random_bytes(1) {
    <<n>> -> int.to_float(n) /. 255.0
    _ -> 0.5
  }
}
