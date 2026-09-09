import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
/// 503 を Status(503) として表面化させる。透過リトライの代わりに、
/// Retry-After は vectum のポリシー層で尊重する (#37): FFI が応答ヘッダを
/// 解釈し、有効なら Status に delay (ms) のヒントを載せて返す。
/// https は FFI 側でサーバ証明書をシステム CA ストアに対して検証する。
@external(erlang, "vectum_httpc_ffi", "post")
fn post(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
  timeout_ms: Int,
) -> Result(#(Int, Option(Int)), String)

pub type Outgoing {
  Outgoing(
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

pub type SendResult {
  /// HTTP 応答。`retry_after_ms` は FFI が retry 対象 (408/429/5xx) の
  /// 応答ヘッダ Retry-After から解釈した delay (ms)。有効なときのみ
  /// `Some` で、`None` はヘッダなし・不正・形式不明・非 retry 対象を表す。
  Status(status: Int, retry_after_ms: Option(Int))
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
            now_ms
              + retry.next_delay_ms(
              policy,
              attempts,
              jitter_unit,
              retry_after_ms(result),
            ),
            error,
          )
      }
  }
}

/// 応答に載っている Retry-After delay (ms)。タイムアウト・接続失敗や
/// ヒントの無いステータスは None。decide の Retry 分岐でのみ参照される。
fn retry_after_ms(result: SendResult) -> Option(Int) {
  case result {
    Status(_, retry_after_ms) -> retry_after_ms
    TimedOut | ConnectFailed(_) -> None
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
        Ok(#(status, retry_after_ms)) -> Status(status, retry_after_ms)
        Error("timeout") -> TimedOut
        Error(reason) -> ConnectFailed(reason)
      }
    }
  }
}

fn to_attempt(result: SendResult) -> retry.AttemptResult {
  case result {
    Status(status, _) -> retry.HttpStatus(status)
    TimedOut -> retry.Timeout
    ConnectFailed(_) -> retry.ConnectionError
  }
}

fn describe(result: SendResult) -> String {
  case result {
    // クランプが起きたことは last_error の説明文で分かるようにする (#37)。
    Status(status, Some(retry_after_ms))
      if retry_after_ms > retry.retry_after_max_ms
    ->
      "http "
      <> int.to_string(status)
      <> " retry-after "
      <> int.to_string(retry_after_ms)
      <> "ms clamped to "
      <> int.to_string(retry.retry_after_max_ms)
      <> "ms"
    Status(status, _) -> "http " <> int.to_string(status)
    TimedOut -> "timeout"
    ConnectFailed(reason) -> reason
  }
}
