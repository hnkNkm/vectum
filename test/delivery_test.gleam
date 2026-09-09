import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import vectum/config.{HttpDestination}
import vectum/delivery
import vectum/event
import vectum/retry.{type Policy, Policy}

fn ev() -> event.Event {
  event.Event(
    id: "evt",
    source: "github",
    event_type: "push",
    timestamp: "t",
    data: event.Object(dict.new()),
    metadata: dict.new(),
  )
}

fn policy() -> Policy {
  Policy(8, 1000, 60_000, 10_000, False)
}

pub fn outgoing_includes_idempotency_headers_test() {
  let dest =
    HttpDestination(
      name: "audit",
      url: "http://127.0.0.1:9/events",
      timeout_ms: Some(1234),
      hmac_secret: Some("out"),
      hmac_header: "X-Vectum-Signature",
    )
  let outgoing = delivery.build_outgoing(dest, ev(), 9999)
  assert outgoing.url == "http://127.0.0.1:9/events"
  assert outgoing.timeout_ms == 1234
  assert list.key_find(outgoing.headers, "x-event-id") == Ok("evt")
  assert list.key_find(outgoing.headers, "idempotency-key") == Ok("evt")
  assert list.key_find(outgoing.headers, "content-type")
    == Ok("application/json")
  let assert Ok(_) = list.key_find(outgoing.headers, "x-vectum-signature")
}

pub fn decide_success_retry_and_dead_test() {
  let p = policy()
  let assert delivery.Succeeded(1) =
    delivery.decide(p, 0, delivery.Status(204, None), 0, 0.0)
  let assert delivery.RetryScheduled(1, 1000, "http 500") =
    delivery.decide(p, 0, delivery.Status(500, None), 0, 0.0)
  let assert delivery.DeadLettered(1, "http 400") =
    delivery.decide(p, 0, delivery.Status(400, None), 0, 0.0)
  let assert delivery.DeadLettered(8, "timeout") =
    delivery.decide(p, 7, delivery.TimedOut, 0, 0.0)
}

/// #37: 429 + `Retry-After: 2` (delta-seconds) が届いたら、exponential
/// backoff でなくサーバ指定どおり now + 2000ms に次回試行を予約する。
/// jitter は適用しない。試行回数が進んでもサーバ指定が優先する。
pub fn decide_retry_after_delta_seconds_test() {
  let p = policy()
  let assert delivery.RetryScheduled(1, 2000, "http 429") =
    delivery.decide(p, 0, delivery.Status(429, Some(2000)), 0, 0.0)
  let assert delivery.RetryScheduled(3, 8000, "http 429") =
    delivery.decide(p, 2, delivery.Status(429, Some(2000)), 6000, 0.5)
}

/// #37: ヘッダなし・不正・形式不明 (FFI が None に正規化) は従来の
/// exponential backoff のまま。
pub fn decide_retry_after_absent_falls_back_to_backoff_test() {
  let p = policy()
  let assert delivery.RetryScheduled(1, 1000, "http 429") =
    delivery.decide(p, 0, delivery.Status(429, None), 0, 0.0)
  let assert delivery.RetryScheduled(2, 2000, "http 503") =
    delivery.decide(p, 1, delivery.Status(503, None), 0, 0.0)
}

/// #37: HTTP-date が過去 (FFI が Some(0) に正規化) なら即時 (now + 0)。
pub fn decide_retry_after_past_date_is_immediate_test() {
  let assert delivery.RetryScheduled(1, 0, "http 429") =
    delivery.decide(policy(), 0, delivery.Status(429, Some(0)), 0, 0.0)
}

/// #37: 過大な Retry-After は retry_after_max_ms (24h) にクランプされる。
/// クランプの事実は last_error になる error 文字列に残る。
pub fn decide_retry_after_clamped_to_24h_test() {
  let assert delivery.RetryScheduled(1, next, error) =
    delivery.decide(
      policy(),
      0,
      delivery.Status(429, Some(999_999_999_999_000)),
      0,
      0.0,
    )
  assert next == retry.retry_after_max_ms
  assert error == "http 429 retry-after 999999999999000ms clamped to 86400000ms"
}

/// #37: 上限ちょうどの値はクランプされない (説明文も通常のまま)。
pub fn decide_retry_after_exactly_at_cap_is_not_clamped_test() {
  let assert delivery.RetryScheduled(1, next, "http 429") =
    delivery.decide(
      policy(),
      0,
      delivery.Status(429, Some(retry.retry_after_max_ms)),
      0,
      0.0,
    )
  assert next == retry.retry_after_max_ms
}

pub fn decide_internal_error_uses_backoff_then_dead_test() {
  let p = policy()
  let assert delivery.RetryScheduled(1, 1000, "unknown destination ci") =
    delivery.decide(
      p,
      0,
      delivery.ConnectFailed("unknown destination ci"),
      0,
      0.0,
    )
  let assert delivery.RetryScheduled(3, 4000, "db locked") =
    delivery.decide(p, 2, delivery.ConnectFailed("db locked"), 0, 0.0)
  let assert delivery.DeadLettered(8, "unknown destination ci") =
    delivery.decide(
      p,
      7,
      delivery.ConnectFailed("unknown destination ci"),
      0,
      0.0,
    )
}

pub fn default_timeout_used_when_destination_omits_it_test() {
  let dest =
    HttpDestination(
      name: "audit",
      url: "http://127.0.0.1:9/events",
      timeout_ms: None,
      hmac_secret: None,
      hmac_header: "X-Vectum-Signature",
    )
  assert delivery.build_outgoing(dest, ev(), 4321).timeout_ms == 4321
}

/// #54-2: 接続失敗の詳細(DNS/TLS/posix 原因)を捨てずに残す。
pub fn connect_failed_preserves_detail_test() {
  let outgoing =
    delivery.Outgoing(
      url: "http://127.0.0.1:9/events",
      headers: [],
      body: "{}",
      timeout_ms: 2000,
    )
  let result = delivery.send_http(outgoing)
  case result {
    delivery.ConnectFailed(reason) -> {
      assert reason != "connection error"
      assert string.contains(reason, "FailedToConnect")
      let assert delivery.RetryScheduled(_, _, error) =
        delivery.decide(policy(), 0, result, 0, 0.0)
      assert string.contains(error, "FailedToConnect")
    }
    _ -> panic as "expected ConnectFailed for closed port"
  }
}

@external(erlang, "retry_after_ffi", "start")
fn retry_after_server_start() -> Int

@external(erlang, "retry_after_ffi", "start")
fn retry_after_server_start_scenario(scenario: String) -> Int

@external(erlang, "retry_after_ffi", "request_count")
fn retry_after_server_count(port: Int) -> Int

@external(erlang, "retry_after_ffi", "stop")
fn retry_after_server_stop(port: Int) -> Nil

/// F1: httpc の透過リトライ (autoretry) を無効化している。
/// 503 + `Retry-After: 1` に 1 回だけ POST が届き、503 がそのまま
/// Status(503, Some(1000)) として返る。以降の再送タイミングは vectum の
/// ポリシー層 (decide) が決める (#37): このポリシーでは 1 回目の backoff
/// も 1000ms のため、予約時刻は同じ値になる。
pub fn no_hidden_autoretry_on_503_retry_after_test() {
  let port = retry_after_server_start()
  let outgoing =
    delivery.Outgoing(
      url: "http://127.0.0.1:" <> int.to_string(port) <> "/events",
      headers: [#("content-type", "application/json")],
      body: "{}",
      timeout_ms: 5000,
    )
  let result = delivery.send_http(outgoing)
  // Retry-After: 1 の再送窓 (1 秒) を空けてから数える。透過リトライが
  // 生きていたらここで 2 回目の POST が届いている。
  process.sleep(1500)
  let count = retry_after_server_count(port)
  retry_after_server_stop(port)
  let assert delivery.Status(503, Some(1000)) = result
  let assert 1 = count
  let assert delivery.RetryScheduled(1, 1000, "http 503") =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

/// シナリオ応答を返すローカルサーバに 1 回だけ POST し、結果を返す。
/// サーバは必ず閉じる。POST が 2 回以上届いたら (httpc の透過リトライ
/// など) assert で失敗する。
fn scenario_result(scenario: String) -> delivery.SendResult {
  let port = retry_after_server_start_scenario(scenario)
  let outgoing =
    delivery.Outgoing(
      url: "http://127.0.0.1:" <> int.to_string(port) <> "/events",
      headers: [#("content-type", "application/json")],
      body: "{}",
      timeout_ms: 5000,
    )
  let result = delivery.send_http(outgoing)
  let count = retry_after_server_count(port)
  retry_after_server_stop(port)
  let assert 1 = count
  result
}

/// #37: 実 HTTP 配送で 429 + `Retry-After: 2` を受けると FFI が
/// Some(2000) を返し、decide が now + 2000ms に次回試行を予約する。
pub fn send_http_honors_retry_after_delta_test() {
  let result = scenario_result("ra2")
  let assert delivery.Status(429, Some(2000)) = result
  let assert delivery.RetryScheduled(1, 2000, "http 429") =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

/// #37: malformed な Retry-After (delta-seconds でも HTTP-date でもない)
/// は None に正規化され、従来の exponential backoff にフォールバックする。
pub fn send_http_malformed_retry_after_falls_back_test() {
  let result = scenario_result("malformed")
  let assert delivery.Status(429, None) = result
  let assert delivery.RetryScheduled(1, 1000, "http 429") =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

/// #37: HTTP-date 形式の Retry-After が過去の日時 (1 時間前) なら
/// delay 0ms に正規化され、即時 (now + 0) に次回試行が予約される。
pub fn send_http_retry_after_past_http_date_is_immediate_test() {
  let result = scenario_result("past_date")
  let assert delivery.Status(429, Some(0)) = result
  let assert delivery.RetryScheduled(1, 0, "http 429") =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

/// #37: 過大な Retry-After (delta-seconds) は 24h 上限にクランプされ、
/// last_error の説明文にその事実が残る。
pub fn send_http_retry_after_huge_value_is_clamped_test() {
  let result = scenario_result("huge")
  let assert delivery.Status(429, Some(999_999_999_999_000)) = result
  let assert delivery.RetryScheduled(1, next, error) =
    delivery.decide(policy(), 0, result, 0, 0.0)
  assert next == retry.retry_after_max_ms
  assert error == "http 429 retry-after 999999999999000ms clamped to 86400000ms"
}

/// #37: 2xx は従来どおり success (Retry-After は読まれない)。
pub fn send_http_ok_is_success_test() {
  let result = scenario_result("ok200")
  let assert delivery.Status(200, None) = result
  let assert delivery.Succeeded(1) =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

/// #37: retry 対象外の 4xx は従来どおり dead letter。
pub fn send_http_bad_request_is_dead_letter_test() {
  let result = scenario_result("bad400")
  let assert delivery.Status(400, None) = result
  let assert delivery.DeadLettered(1, "http 400") =
    delivery.decide(policy(), 0, result, 0, 0.0)
}

@external(erlang, "tls_ffi", "start")
fn tls_server_start() -> Int

@external(erlang, "tls_ffi", "request_count")
fn tls_server_count(port: Int) -> Int

@external(erlang, "tls_ffi", "stop")
fn tls_server_stop(port: Int) -> Nil

@external(erlang, "tls_ffi", "control_get")
fn tls_control_get(port: Int) -> Int

/// F2: https 配送は自己署名証明書のサーバを拒否する (verify_peer +
/// システム CA ストア)。TLS ハンドシェイクが届かないためサーバ側の
/// HTTP リクエスト数は 0 のまま。
pub fn https_rejects_self_signed_cert_test() {
  let port = tls_server_start()
  let outgoing =
    delivery.Outgoing(
      url: "https://127.0.0.1:" <> int.to_string(port) <> "/events",
      headers: [#("content-type", "application/json")],
      body: "{}",
      timeout_ms: 3000,
    )
  let result = delivery.send_http(outgoing)
  let count = tls_server_count(port)
  tls_server_stop(port)
  case result {
    delivery.ConnectFailed(reason) -> {
      assert string.contains(reason, "FailedToConnect")
      let assert delivery.RetryScheduled(1, 1000, _) =
        delivery.decide(policy(), 0, result, 0, 0.0)
    }
    _ -> panic as "expected ConnectFailed for self-signed https server"
  }
  let assert 0 = count
}

/// F2 control: 検証を無効化した (verify_none) リクエストは同じ自己署名
/// サーバに届く。テストサーバ自体は健全で、拒否が証明書検証によるもの
/// だと確認する。
pub fn https_self_signed_server_reachable_without_verification_test() {
  let port = tls_server_start()
  let assert 200 = tls_control_get(port)
  let assert 1 = tls_server_count(port)
  tls_server_stop(port)
}
