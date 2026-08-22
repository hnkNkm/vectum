import gleam/float
import gleam/int

pub type Policy {
  Policy(
    max_attempts: Int,
    initial_backoff_ms: Int,
    max_backoff_ms: Int,
    timeout_ms: Int,
    jitter: Bool,
  )
}

pub type Outcome {
  Success
  Retry
  Fail
}

pub type AttemptResult {
  HttpStatus(Int)
  Timeout
  ConnectionError
}

pub fn classify(result: AttemptResult) -> Outcome {
  case result {
    HttpStatus(status) if status >= 200 && status < 300 -> Success
    HttpStatus(408) | HttpStatus(429) -> Retry
    HttpStatus(status) if status >= 500 && status < 600 -> Retry
    Timeout | ConnectionError -> Retry
    HttpStatus(_) -> Fail
  }
}

/// `attempts` is the number of tries already performed (1 after the first send).
pub fn backoff_ms(policy: Policy, attempts: Int, jitter_unit: Float) -> Int {
  let base =
    capped_exponential(
      policy.initial_backoff_ms,
      attempts,
      policy.max_backoff_ms,
    )
  case policy.jitter {
    False -> base
    True -> apply_jitter(base, jitter_unit)
  }
}

pub fn is_exhausted(policy: Policy, attempts: Int) -> Bool {
  attempts >= policy.max_attempts
}

fn capped_exponential(initial: Int, attempts: Int, max: Int) -> Int {
  let steps = case attempts <= 1 {
    True -> 0
    False -> attempts - 1
  }
  scale(initial, steps, max)
}

fn scale(current: Int, remaining: Int, max: Int) -> Int {
  case remaining <= 0 {
    True -> int.min(current, max)
    False -> {
      let next = current * 2
      case next > max || next < current {
        True -> max
        False -> scale(next, remaining - 1, max)
      }
    }
  }
}

fn apply_jitter(base: Int, unit: Float) -> Int {
  let clamped = case unit <. 0.0 {
    True -> 0.0
    False ->
      case unit >. 1.0 {
        True -> 1.0
        False -> unit
      }
  }
  let half = base / 2
  half + float.round(int.to_float(half) *. clamped)
}
