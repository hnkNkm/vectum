import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import vectum/config.{type Destination, HttpDestination}
import vectum/event.{type Event}
import vectum/hmac
import vectum/retry.{type Policy}

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
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_body(outgoing.body)
        |> set_headers(outgoing.headers)
      let config =
        httpc.configure()
        |> httpc.timeout(outgoing.timeout_ms)
      case httpc.dispatch(config, req) {
        Ok(response) -> Status(response.status)
        Error(httpc.ResponseTimeout) -> TimedOut
        Error(httpc.FailedToConnect(..)) -> ConnectFailed("connection error")
        Error(other) -> ConnectFailed(string.inspect(other))
      }
    }
  }
}

fn set_headers(
  req: request.Request(String),
  headers: List(#(String, String)),
) -> request.Request(String) {
  list.fold(headers, req, fn(acc, header) {
    request.set_header(acc, header.0, header.1)
  })
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
