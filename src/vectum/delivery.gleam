import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import vectum/config.{type Destination, HttpDestination}
import vectum/event.{type Event}
import vectum/hmac
import vectum/retry.{type Policy}

/// gleam_httpc は per-request HTTP options に {autoretry, 0} を渡せないため、
/// 配送 POST は直接 httpc を呼ぶ Erlang FFI を使う。OTP の httpc 既定は
/// autoretry = infinity で、503 + Retry-After をタイムアウト内に透過再送する
/// (F1)。vectum のリトライ勘定・backoff から隠れる再送を防ぐため無効化し、
/// 503 を Status(503) として表面化させる。https は FFI 側でサーバ証明書を
/// システム CA ストアに対して検証する。
@external(erlang, "vectum_httpc_ffi", "post")
fn post(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
  timeout_ms: Int,
) -> Result(Int, String)

pub type Outgoing {
  Outgoing(
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

pub type SendResult {
  Status(Int)
  TimedOut
  ConnectFailed(String)
}

pub type Update {
  Succeeded(attempts: Int)
  RetryScheduled(attempts: Int, next_attempt_at: Int, error: String)
  DeadLettered(attempts: Int, error: String)
}

pub fn build_outgoing(
  destination: Destination,
  event: Event,
  default_timeout_ms: Int,
) -> Outgoing {
  let HttpDestination(url:, timeout_ms:, hmac_secret:, hmac_header:, ..) =
    destination
  let body = event.envelope_string(event)
  let timeout = option.unwrap(timeout_ms, default_timeout_ms)
  let headers = [
    #("content-type", "application/json"),
    #("x-event-id", event.id),
    #("idempotency-key", event.id),
  ]
  let headers = case hmac_secret {
    None -> headers
    Some(secret) -> [
      #(string.lowercase(hmac_header), hmac.sign_string(secret, body)),
      ..headers
    ]
  }
  Outgoing(url:, headers:, body:, timeout_ms: timeout)
}

pub fn decide(
  policy: Policy,
  previous_attempts: Int,
  result: SendResult,
  now_ms: Int,
  jitter_unit: Float,
) -> Update {
  let attempts = previous_attempts + 1
  let outcome = retry.classify(to_attempt(result))
  let error = describe(result)
  case outcome {
    retry.Success -> Succeeded(attempts)
    retry.Fail -> DeadLettered(attempts, error)
    retry.Retry ->
      case retry.is_exhausted(policy, attempts) {
        True -> DeadLettered(attempts, error)
        False ->
          RetryScheduled(
            attempts,
            now_ms + retry.backoff_ms(policy, attempts, jitter_unit),
            error,
          )
      }
  }
}

pub fn send_http(outgoing: Outgoing) -> SendResult {
  case request.to(outgoing.url) {
    Error(_) -> ConnectFailed("invalid destination url")
    Ok(_) -> {
      let content_type =
        outgoing.headers
        |> list.key_find("content-type")
        |> result.unwrap("application/json")
      case
        post(
          outgoing.url,
          outgoing.headers,
          content_type,
          outgoing.body,
          outgoing.timeout_ms,
        )
      {
        Ok(status) -> Status(status)
        Error("timeout") -> TimedOut
        Error(reason) -> ConnectFailed(reason)
      }
    }
  }
}

fn to_attempt(result: SendResult) -> retry.AttemptResult {
  case result {
    Status(status) -> retry.HttpStatus(status)
    TimedOut -> retry.Timeout
    ConnectFailed(_) -> retry.ConnectionError
  }
}

fn describe(result: SendResult) -> String {
  case result {
    Status(status) -> "http " <> int.to_string(status)
    TimedOut -> "timeout"
    ConnectFailed(reason) -> reason
  }
}
