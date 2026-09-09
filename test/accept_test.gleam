import gleam/dict
import gleam/list
import gleam/string
import vectum/accept
import vectum/config
import vectum/hmac

const toml = "
[[sources]]
name = \"github\"
type_from_header = \"X-GitHub-Event\"
hmac_secret = \"s3cret\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"audit\"
url = \"http://127.0.0.1:9/events\"

[[routes]]
name = \"push\"
source = \"github\"
event = \"push\"
destinations = [\"audit\"]
"

fn cfg() -> config.Config {
  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  parsed
}

pub fn unknown_source_is_404_test() {
  let assert Error(accept.Reject(404, "unknown source")) =
    accept.normalize(cfg(), "nope", "application/json", [], "{}", "t", "id")
}

pub fn invalid_content_type_is_415_test() {
  let assert Error(accept.Reject(415, "invalid content-type")) =
    accept.normalize(cfg(), "internal", "text/plain", [], "{}", "t", "id")
}

pub fn invalid_json_is_400_test() {
  let assert Error(accept.Reject(400, "invalid json")) =
    accept.normalize(
      cfg(),
      "internal",
      "application/json; charset=utf-8",
      [],
      "{",
      "t",
      "id",
    )
}

pub fn missing_event_type_is_400_test() {
  let body = "{}"
  let assert Error(accept.Reject(400, "missing event type")) =
    accept.normalize(
      cfg(),
      "github",
      "application/json",
      [#("x-hub-signature-256", hmac.sign_string("s3cret", body))],
      body,
      "t",
      "id",
    )
}

pub fn hmac_failure_is_401_test() {
  let assert Error(accept.Reject(401, "hmac failure")) =
    accept.normalize(
      cfg(),
      "github",
      "application/json",
      [
        #("x-github-event", "push"),
        #("x-hub-signature-256", "sha256=deadbeef"),
      ],
      "{}",
      "t",
      "id",
    )
}

pub fn github_push_is_accepted_and_routed_test() {
  let body = "{\"ok\":true}"
  let assert Ok(accept.Accepted(event:, destinations:)) =
    accept.normalize(
      cfg(),
      "github",
      "application/json",
      [
        #("X-GitHub-Event", "push"),
        #("X-Hub-Signature-256", hmac.sign_string("s3cret", body)),
        #("X-GitHub-Delivery", "abc"),
      ],
      body,
      "t",
      "id-1",
    )
  assert event.id == "id-1"
  assert event.event_type == "push"
  assert destinations == ["audit"]
  assert dict.get(event.metadata, "x-github-delivery") == Ok("abc")
  assert dict.get(event.metadata, "x-hub-signature-256") == Error(Nil)
}

pub fn tricky_content_type_is_415_test() {
  let assert Error(accept.Reject(415, "invalid content-type")) =
    accept.normalize(
      cfg(),
      "internal",
      "text/plain; x=application/json",
      [],
      "{}",
      "t",
      "id",
    )
}

pub fn empty_header_event_type_is_missing_test() {
  // 空文字の type header は欠損扱いで fallback せず、空 type で永続化しない。
  // github source には header 以外の type 解決手段がないため 400 になる。
  let body = "{}"
  let assert Error(accept.Reject(400, "missing event type")) =
    accept.normalize(
      cfg(),
      "github",
      "application/json",
      [
        #("x-github-event", ""),
        #("x-hub-signature-256", hmac.sign_string("s3cret", body)),
      ],
      body,
      "t",
      "id",
    )
}

// ---- Bearer Token 認証 (#38) ----

const bearer_token = "tok-secret"

const bearer_toml = "
[[sources]]
name = \"tok\"
type_fixed = \"ping\"
auth_bearer = \"tok-secret\"

[[sources]]
name = \"both\"
type_fixed = \"ping\"
hmac_secret = \"hmac-secret\"
auth_bearer = \"tok-secret\"

[[destinations]]
name = \"audit\"
url = \"http://127.0.0.1:9/events\"

[[routes]]
name = \"tok-ping\"
source = \"tok\"
event = \"ping\"
destinations = [\"audit\"]

[[routes]]
name = \"both-ping\"
source = \"both\"
event = \"ping\"
destinations = [\"audit\"]
"

fn bearer_cfg() -> config.Config {
  let assert Ok(parsed) = config.parse_with(bearer_toml, fn(_) { Error(Nil) })
  parsed
}

pub fn bearer_valid_token_is_accepted_test() {
  let assert Ok(accept.Accepted(event:, destinations:)) =
    accept.normalize(
      bearer_cfg(),
      "tok",
      "application/json",
      [#("authorization", "Bearer " <> bearer_token)],
      "{}",
      "t",
      "id",
    )
  assert event.event_type == "ping"
  assert destinations == ["audit"]
  // Authorization は設定の有無にかかわらず Metadata に載らない。
  assert dict.get(event.metadata, "authorization") == Error(Nil)
  assert dict.get(event.metadata, "Authorization") == Error(Nil)
  // token が Metadata のどの値にも漏れないこと。
  assert list.all(dict.values(event.metadata), fn(value) {
    !string.contains(value, bearer_token)
  })
}

pub fn bearer_scheme_is_case_insensitive_test() {
  // RFC 7235: scheme 名は大小文字非依存。
  let assert Ok(accept.Accepted(..)) =
    accept.normalize(
      bearer_cfg(),
      "tok",
      "application/json",
      [#("authorization", "bearer " <> bearer_token)],
      "{}",
      "t",
      "id",
    )
}

pub fn bearer_missing_token_is_401_test() {
  let assert Error(accept.Reject(401, "bearer failure")) =
    accept.normalize(
      bearer_cfg(),
      "tok",
      "application/json",
      [],
      "{}",
      "t",
      "id",
    )
}

pub fn bearer_wrong_or_malformed_token_is_401_test() {
  // 誤 token・別 scheme・形式不正はいずれも 401。reason に token は出ない。
  let bad = [
    "Bearer not-the-token",
    "Basic dXNlcjpwYXNz",
    "bearer",
    "Bearer a b",
    "Bearer " <> bearer_token <> " extra",
    "",
  ]
  assert list.all(bad, fn(value) {
    case
      accept.normalize(
        bearer_cfg(),
        "tok",
        "application/json",
        [#("authorization", value)],
        "{}",
        "t",
        "id",
      )
    {
      Error(accept.Reject(status, reason)) ->
        status == 401
        && !string.contains(reason, bearer_token)
        && !string.contains(reason, "not-the-token")
      _ -> False
    }
  })
}

/// #38: HMAC と Bearer を両方設定した Source は両方合格しないと受理しない (AND)。
pub fn bearer_and_hmac_must_both_pass_test() {
  let body = "{}"
  let signed = [#("x-hub-signature-256", hmac.sign_string("hmac-secret", body))]

  // 両方正しい → 受理
  let assert Ok(accept.Accepted(..)) =
    accept.normalize(
      bearer_cfg(),
      "both",
      "application/json",
      [#("authorization", "Bearer " <> bearer_token), ..signed],
      body,
      "t",
      "id",
    )
  // HMAC 不一致は Bearer が正しくても拒否
  let assert Error(accept.Reject(401, "hmac failure")) =
    accept.normalize(
      bearer_cfg(),
      "both",
      "application/json",
      [
        #("authorization", "Bearer " <> bearer_token),
        #("x-hub-signature-256", "sha256=deadbeef"),
      ],
      body,
      "t",
      "id",
    )
  // Bearer 不一致は HMAC が正しくても拒否
  let assert Error(accept.Reject(401, "bearer failure")) =
    accept.normalize(
      bearer_cfg(),
      "both",
      "application/json",
      [#("authorization", "Bearer nope"), ..signed],
      body,
      "t",
      "id",
    )
  // Authorization 自体が無い場合も拒否
  let assert Error(accept.Reject(401, "bearer failure")) =
    accept.normalize(
      bearer_cfg(),
      "both",
      "application/json",
      signed,
      body,
      "t",
      "id",
    )
}

pub fn bearer_not_configured_source_still_passes_without_auth_test() {
  // Bearer 未設定の Source は Authorization 無しでも従来どおり通る。
  // internal source は type_from_json で event type を解決する。
  let assert Ok(accept.Accepted(..)) =
    accept.normalize(
      cfg(),
      "internal",
      "application/json",
      [],
      "{\"type\":\"ping\"}",
      "t",
      "id",
    )
}
