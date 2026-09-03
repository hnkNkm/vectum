import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/string

pub type Metrics {
  Metrics(subject: Subject(Message))
}

pub type Snapshot {
  Snapshot(
    events_received: Int,
    events_rejected: Int,
    deliveries: Int,
    deliveries_success: Int,
    deliveries_retry: Int,
    deliveries_dead: Int,
    latency_sum_ms: Int,
    latency_count: Int,
    reaped: Int,
  )
}

pub type Message {
  Received
  Rejected
  DeliveryAttempt
  DeliverySuccess(latency_ms: Int)
  DeliveryRetry
  DeliveryDead
  Reaped(Int)
  Read(reply: Subject(Snapshot))
}

pub fn start() -> Result(Metrics, String) {
  case start_supervised() {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(string.inspect(e))
  }
}

/// Supervisor 配下用。Started をそのまま返す。
pub fn start_supervised() -> Result(actor.Started(Metrics), actor.StartError) {
  case
    actor.new(empty())
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> Ok(actor.Started(..started, data: Metrics(started.data)))
    Error(e) -> Error(e)
  }
}

pub fn empty() -> Snapshot {
  Snapshot(0, 0, 0, 0, 0, 0, 0, 0, 0)
}

pub fn record_received(metrics: Metrics) -> Nil {
  process.send(metrics.subject, Received)
}

pub fn record_rejected(metrics: Metrics) -> Nil {
  process.send(metrics.subject, Rejected)
}

pub fn record_attempt(metrics: Metrics) -> Nil {
  process.send(metrics.subject, DeliveryAttempt)
}

pub fn record_success(metrics: Metrics, latency_ms: Int) -> Nil {
  process.send(metrics.subject, DeliverySuccess(latency_ms))
}

pub fn record_retry(metrics: Metrics) -> Nil {
  process.send(metrics.subject, DeliveryRetry)
}

pub fn record_dead(metrics: Metrics) -> Nil {
  process.send(metrics.subject, DeliveryDead)
}

/// 滞留 delivering を再開した数を記録する。
pub fn record_reaped(metrics: Metrics, count: Int) -> Nil {
  process.send(metrics.subject, Reaped(count))
}

/// process.call は応答なし・先方死で panic するため、監視付き select で待つ。
/// 輸送失敗は Error にして返し、呼出側(/metrics・監視木)は落とさない。
type CallOutcome {
  CallReply(Snapshot)
  CalleeDown
}

pub fn snapshot(metrics: Metrics) -> Result(Snapshot, Nil) {
  let reply_subject = process.new_subject()
  case process.subject_owner(metrics.subject) {
    Error(_) -> Error(Nil)
    Ok(callee) -> {
      let monitor = process.monitor(callee)
      process.send(metrics.subject, Read(reply_subject))
      let selector =
        process.new_selector()
        |> process.select_map(reply_subject, CallReply)
        |> process.select_specific_monitor(monitor, fn(_) { CalleeDown })
      let outcome = process.selector_receive(selector, 1000)
      process.demonitor_process(monitor)
      case outcome {
        Ok(CallReply(snap)) -> Ok(snap)
        _ -> Error(Nil)
      }
    }
  }
}

pub fn prometheus(snapshot: Snapshot, pending: Int) -> String {
  lines([
    comment("events_received_total", "Events accepted after persistence"),
    type_line("events_received_total", "counter"),
    metric("events_received_total", snapshot.events_received),
    comment("events_rejected_total", "Events rejected before persistence"),
    type_line("events_rejected_total", "counter"),
    metric("events_rejected_total", snapshot.events_rejected),
    comment("deliveries_total", "Delivery attempts"),
    type_line("deliveries_total", "counter"),
    metric("deliveries_total", snapshot.deliveries),
    comment("deliveries_success_total", "Successful deliveries"),
    type_line("deliveries_success_total", "counter"),
    metric("deliveries_success_total", snapshot.deliveries_success),
    comment("deliveries_retry_total", "Retried deliveries"),
    type_line("deliveries_retry_total", "counter"),
    metric("deliveries_retry_total", snapshot.deliveries_retry),
    comment("deliveries_dead_total", "Dead-lettered deliveries"),
    type_line("deliveries_dead_total", "counter"),
    metric("deliveries_dead_total", snapshot.deliveries_dead),
    comment(
      "deliveries_reaped_total",
      "Stale deliveries requeued by the reaper",
    ),
    type_line("deliveries_reaped_total", "counter"),
    metric("deliveries_reaped_total", snapshot.reaped),
    comment("delivery_latency_milliseconds_sum", "Delivery latency sum"),
    type_line("delivery_latency_milliseconds_sum", "counter"),
    metric("delivery_latency_milliseconds_sum", snapshot.latency_sum_ms),
    comment("delivery_latency_milliseconds_count", "Delivery latency samples"),
    type_line("delivery_latency_milliseconds_count", "counter"),
    metric("delivery_latency_milliseconds_count", snapshot.latency_count),
    comment("pending_deliveries", "Incomplete deliveries"),
    type_line("pending_deliveries", "gauge"),
    metric("pending_deliveries", pending),
  ])
}

fn handle(state: Snapshot, message: Message) -> actor.Next(Snapshot, Message) {
  let next = case message {
    Received -> Snapshot(..state, events_received: state.events_received + 1)
    Rejected -> Snapshot(..state, events_rejected: state.events_rejected + 1)
    DeliveryAttempt -> Snapshot(..state, deliveries: state.deliveries + 1)
    DeliveryRetry ->
      Snapshot(..state, deliveries_retry: state.deliveries_retry + 1)
    DeliveryDead ->
      Snapshot(..state, deliveries_dead: state.deliveries_dead + 1)
    Reaped(count) -> Snapshot(..state, reaped: state.reaped + count)
    DeliverySuccess(latency_ms) ->
      Snapshot(
        ..state,
        deliveries_success: state.deliveries_success + 1,
        latency_sum_ms: state.latency_sum_ms + latency_ms,
        latency_count: state.latency_count + 1,
      )
    Read(reply) -> {
      process.send(reply, state)
      state
    }
  }
  actor.continue(next)
}

fn comment(name: String, help: String) -> String {
  "# HELP " <> name <> " " <> help
}

fn type_line(name: String, kind: String) -> String {
  "# TYPE " <> name <> " " <> kind
}

fn metric(name: String, value: Int) -> String {
  name <> " " <> int.to_string(value)
}

fn lines(items: List(String)) -> String {
  string.join(items, "\n") <> "\n"
}
