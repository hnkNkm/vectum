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
