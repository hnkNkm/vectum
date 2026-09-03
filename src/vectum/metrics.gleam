import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
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
    // delivery_latency_seconds ヒストグラムの有限 bucket 累積数。
    // 要素は histogram_bucket_edges_ms の各境界(ミリ秒)に対応し、境界以下のサンプル数を数える。
    latency_buckets: List(Int),
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
  Snapshot(
    events_received: 0,
    events_rejected: 0,
    deliveries: 0,
    deliveries_success: 0,
    deliveries_retry: 0,
    deliveries_dead: 0,
    latency_sum_ms: 0,
    latency_count: 0,
    latency_buckets: zero_buckets(),
    reaped: 0,
  )
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
  let counters = [
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
  ]
  let histogram_lines = latency_histogram_lines(snapshot)
  let gauges = [
    comment("pending_deliveries", "Incomplete deliveries"),
    type_line("pending_deliveries", "gauge"),
    metric("pending_deliveries", pending),
  ]
  lines(
    counters
    |> list.append(histogram_lines)
    |> list.append(gauges),
  )
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
        latency_buckets: accumulate_buckets(state.latency_buckets, latency_ms),
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

/// delivery_latency_seconds ヒストグラムの bucket 境界(ミリ秒・昇順)。
/// bucket は「境界以下のサンプル数」を累積で数えるため、Float にせず整数のまま比較する。
const histogram_bucket_edges_ms = [
  5,
  10,
  25,
  50,
  100,
  250,
  500,
  1000,
  2500,
  5000,
  10_000,
]

/// 全 bucket を 0 で初期化する(histogram_bucket_edges_ms と同長)。
fn zero_buckets() -> List(Int) {
  list.map(histogram_bucket_edges_ms, fn(_) { 0 })
}

/// サンプル 1 件を累積 bucket に反映する。境界ちょうどの値はその bucket に数える。
fn accumulate_buckets(buckets: List(Int), latency_ms: Int) -> List(Int) {
  list.zip(buckets, histogram_bucket_edges_ms)
  |> list.map(fn(entry) {
    let #(count, edge_ms) = entry
    case latency_ms <= edge_ms {
      True -> count + 1
      False -> count
    }
  })
}

/// delivery_latency_seconds の出力行(HELP / TYPE / bucket / sum / count)。
/// histogram の sum / count はミリ秒カウンタと同じサンプルを数えるため、
/// latency_sum_ms / latency_count を秒表記へ変換して使う。
fn latency_histogram_lines(snapshot: Snapshot) -> List(String) {
  let family = "delivery_latency_seconds"
  let header = [
    comment(family, "Delivery latency in seconds"),
    type_line(family, "histogram"),
  ]
  let bucket_lines =
    list.zip(histogram_bucket_edges_ms, snapshot.latency_buckets)
    |> list.map(fn(entry) {
      let #(edge_ms, count) = entry
      bucket_line(family, ms_to_seconds_str(edge_ms), count)
    })
  let total = snapshot.latency_count
  let tail = [
    bucket_line(family, "+Inf", total),
    metric_str(family <> "_sum", ms_to_seconds_str(snapshot.latency_sum_ms)),
    metric_str(family <> "_count", int.to_string(total)),
  ]
  header
  |> list.append(bucket_lines)
  |> list.append(tail)
}

fn bucket_line(family: String, le: String, count: Int) -> String {
  family <> "_bucket{le=\"" <> le <> "\"} " <> int.to_string(count)
}

/// 値が String のメトリクス行(histogram の sum など)。
fn metric_str(name: String, value: String) -> String {
  name <> " " <> value
}

/// ミリ秒を秒の小数表記にする(5 -> "0.005"、2500 -> "2.5"、12000 -> "12")。
/// Float を経由しない整数演算のため、丸めによる表記ゆれがない。
fn ms_to_seconds_str(ms: Int) -> String {
  let whole = ms / 1000
  let frac_ms = ms % 1000
  case frac_ms {
    0 -> int.to_string(whole)
    _ -> {
      let frac =
        strip_trailing_zeros(string.pad_start(
          int.to_string(frac_ms),
          to: 3,
          with: "0",
        ))
      int.to_string(whole) <> "." <> frac
    }
  }
}

/// 小数部の末尾の 0 を取り除く("050" -> "05"、500 -> "5"、"005" はそのまま)。
fn strip_trailing_zeros(s: String) -> String {
  case string.ends_with(s, "0") {
    True -> strip_trailing_zeros(string.remove_suffix(from: s, matching: "0"))
    False -> s
  }
}
