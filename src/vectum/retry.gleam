import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

pub type Policy {
  Policy(
    max_attempts: Int,
    initial_backoff_ms: Int,
    max_backoff_ms: Int,
    timeout_ms: Int,
    jitter: Bool,
  )
}

/// Retry-After の上限 (24 時間)。これより大きい有効値はこの値にクランプ
/// される。クランプの事実は last_error の説明文に残る (#37)。
pub const retry_after_max_ms: Int = 86_400_000

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

/// Retry 対象の応答で次回試行まで待つ delay (ms) を決める (#37)。
///
/// 有効な `Retry-After` (`Some(delay_ms)`、FFI が delta-seconds / HTTP-date
/// を解釈して生成) がある場合は、サーバ指定を尊重して **そのまま** 使う:
/// - backoff / jitter は適用しない (jitter は無効)
/// - サーバ指定より早く retry することはない
/// - `retry_after_max_ms` (24h) でクランプする (クランプの事実は
///   last_error の説明文に載る)
///
/// ヘッダなし・不正・形式不明 (`None`) は従来どおり exponential backoff
/// (+ equal jitter) にフォールバックする。`max_attempts` の扱いは不変
/// (試行回数として数え、尽きたら dead letter)。
pub fn next_delay_ms(
  policy: Policy,
  attempts: Int,
  jitter_unit: Float,
  retry_after_ms: Option(Int),
) -> Int {
  case retry_after_ms {
    Some(ms) -> int.min(ms, retry_after_max_ms)
    None -> backoff_ms(policy, attempts, jitter_unit)
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

/// Equal jitter: `base / 2 + U(0, base / 2)`。戻り値域は `[base / 2, base]`。
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
  half + float.round(int.to_float(base - half) *. clamped)
}
