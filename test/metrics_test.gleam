import gleam/string
import vectum/metrics

pub fn prometheus_export_contains_required_series_test() {
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
      reaped: 0,
    )
  let text = metrics.prometheus(snap, 7)
  assert string.contains(text, "events_received_total 3")
  assert string.contains(text, "events_rejected_total 1")
  assert string.contains(text, "deliveries_success_total 2")
  assert string.contains(text, "pending_deliveries 7")
}
