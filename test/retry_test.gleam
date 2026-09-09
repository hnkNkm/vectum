import gleam/option.{None, Some}
import vectum/retry.{type Policy, Policy}

fn policy() -> Policy {
  Policy(
    max_attempts: 8,
    initial_backoff_ms: 1000,
    max_backoff_ms: 60_000,
    timeout_ms: 10_000,
    jitter: False,
  )
}

pub fn classify_status_table_test() {
  assert retry.classify(retry.HttpStatus(200)) == retry.Success
  assert retry.classify(retry.HttpStatus(204)) == retry.Success
  assert retry.classify(retry.HttpStatus(301)) == retry.Fail
  assert retry.classify(retry.HttpStatus(400)) == retry.Fail
  assert retry.classify(retry.HttpStatus(408)) == retry.Retry
  assert retry.classify(retry.HttpStatus(429)) == retry.Retry
  assert retry.classify(retry.HttpStatus(500)) == retry.Retry
  assert retry.classify(retry.HttpStatus(503)) == retry.Retry
  assert retry.classify(retry.Timeout) == retry.Retry
  assert retry.classify(retry.ConnectionError) == retry.Retry
}

pub fn exponential_backoff_without_jitter_test() {
  let p = policy()
  assert retry.backoff_ms(p, 1, 0.0) == 1000
  assert retry.backoff_ms(p, 2, 0.0) == 2000
  assert retry.backoff_ms(p, 3, 0.0) == 4000
  assert retry.backoff_ms(p, 7, 0.0) == 60_000
  assert retry.backoff_ms(p, 8, 0.0) == 60_000
}

pub fn jitter_uses_half_plus_fraction_test() {
  let p = Policy(..policy(), jitter: True)
  assert retry.backoff_ms(p, 1, 0.0) == 500
  assert retry.backoff_ms(p, 1, 1.0) == 1000
}

pub fn exhausted_after_max_attempts_test() {
  assert !retry.is_exhausted(policy(), 7)
  assert retry.is_exhausted(policy(), 8)
}

/// #54-3: 奇数 base でも jitter の上限は base(等 jitter の定義どおり)。
pub fn jitter_caps_at_base_for_odd_base_test() {
  let p = Policy(..policy(), jitter: True, initial_backoff_ms: 1001)
  assert retry.backoff_ms(p, 1, 0.0) == 500
  assert retry.backoff_ms(p, 1, 1.0) == 1001
}

/// #37: 有効な Retry-After (Some) は exponential backoff より優先され、
/// そのままの delay になる (jitter も無効)。
pub fn next_delay_prefers_retry_after_over_backoff_test() {
  let p = policy()
  // 2 回目の backoff (2000ms) より短くてもサーバ指定が勝つ。
  assert retry.next_delay_ms(p, 2, 0.0, Some(500)) == 500
  // 何回目でもサーバ指定どおり。
  assert retry.next_delay_ms(p, 7, 0.0, Some(500)) == 500
}

/// #37: Retry-After が有効な間は jitter を適用しない (jitter: True でも
/// jitter_unit に依らず exact な delay)。
pub fn next_delay_applies_no_jitter_to_retry_after_test() {
  let p = Policy(..policy(), jitter: True)
  assert retry.next_delay_ms(p, 1, 0.0, Some(2000)) == 2000
  assert retry.next_delay_ms(p, 1, 1.0, Some(2000)) == 2000
}

/// #37: 上限ちょうどはクランプされない。超過分は retry_after_max_ms (24h)
/// にクランプされる。
pub fn next_delay_clamps_retry_after_at_24h_test() {
  let p = policy()
  assert retry.next_delay_ms(p, 1, 0.0, Some(86_400_000)) == 86_400_000
  assert retry.next_delay_ms(p, 1, 0.0, Some(86_400_001)) == 86_400_000
  assert retry.next_delay_ms(p, 1, 0.0, Some(999_999_999_999_999_999))
    == 86_400_000
}

/// #37: Retry-After なし (None) は従来どおり exponential backoff
/// (+ equal jitter)。
pub fn next_delay_falls_back_to_backoff_without_header_test() {
  let p = policy()
  assert retry.next_delay_ms(p, 1, 0.0, None) == 1000
  assert retry.next_delay_ms(p, 2, 0.0, None) == 2000
  let p = Policy(..policy(), jitter: True)
  assert retry.next_delay_ms(p, 1, 0.0, None) == 500
  assert retry.next_delay_ms(p, 1, 1.0, None) == 1000
}
