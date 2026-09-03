import gleam/list
import gleam/string
import vectum/metrics

pub fn prometheus_export_contains_required_series_test() {
  // 既存系列は変更しない(レイテンシ 2 件は 25ms ずつで sum 50ms / count 2 と整合)。
  let snap =
    metrics.Snapshot(
      events_received: 3,
      events_rejected: 1,
      deliveries: 4,
      deliveries_success: 2,
      deliveries_retry: 1,
      deliveries_dead: 1,
      latency_sum_ms: 50,
      latency_count: 2,
      latency_buckets: [0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2],
      reaped: 0,
    )
  let text = metrics.prometheus(snap, 7)
  assert string.contains(text, "events_received_total 3")
  assert string.contains(text, "events_rejected_total 1")
  assert string.contains(text, "deliveries_success_total 2")
  assert string.contains(text, "pending_deliveries 7")
  // 既存のミリ秒 sum / count は後方互換のためそのまま出す
  assert string.contains(text, "delivery_latency_milliseconds_sum 50")
  assert string.contains(text, "delivery_latency_milliseconds_count 2")
  assert string.contains(text, "# TYPE delivery_latency_seconds histogram")
}

// 各境界ちょうど / 直上の値と 0ms を全境界に対して記録し、累積 bucket を検証する。
pub fn histogram_bucket_boundaries_test() {
  let assert Ok(m) = metrics.start()
  let samples = [
    0,
    5,
    6,
    10,
    11,
    25,
    26,
    50,
    51,
    100,
    101,
    250,
    251,
    500,
    501,
    1000,
    1001,
    2500,
    2501,
    5000,
    5001,
    10_000,
    10_001,
  ]
  list.each(samples, fn(latency) { metrics.record_success(m, latency) })
  let assert Ok(snap) = metrics.snapshot(m)
  // 境界 b の累積 = b 以下のサンプル数。+Inf 相当は latency_count(=成功数)と一致する。
  assert snap.latency_buckets == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22]
  assert snap.latency_count == 23
  assert snap.latency_sum_ms == 38_891
  assert snap.deliveries_success == 23
}

// 小さい既知サンプル(5ms, 500ms)の出力行が期待どおりのテキストになることを検証する。
pub fn histogram_exposition_lines_test() {
  let snap =
    metrics.Snapshot(
      events_received: 0,
      events_rejected: 0,
      deliveries: 2,
      deliveries_success: 2,
      deliveries_retry: 0,
      deliveries_dead: 0,
      latency_sum_ms: 505,
      latency_count: 2,
      latency_buckets: [1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2],
      reaped: 0,
    )
  let text = metrics.prometheus(snap, 0)
  let expected =
    "# HELP delivery_latency_seconds Delivery latency in seconds\n"
    <> "# TYPE delivery_latency_seconds histogram\n"
    <> "delivery_latency_seconds_bucket{le=\"0.005\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.01\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.025\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.05\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.1\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.25\"} 1\n"
    <> "delivery_latency_seconds_bucket{le=\"0.5\"} 2\n"
    <> "delivery_latency_seconds_bucket{le=\"1\"} 2\n"
    <> "delivery_latency_seconds_bucket{le=\"2.5\"} 2\n"
    <> "delivery_latency_seconds_bucket{le=\"5\"} 2\n"
    <> "delivery_latency_seconds_bucket{le=\"10\"} 2\n"
    <> "delivery_latency_seconds_bucket{le=\"+Inf\"} 2\n"
    <> "delivery_latency_seconds_sum 0.505\n"
    <> "delivery_latency_seconds_count 2"
  assert string.contains(text, expected)
  // +Inf bucket / _count は成功数(total 系カウンタ)と同値
  assert string.contains(text, "deliveries_success_total 2")
}
