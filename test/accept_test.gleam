import gleam/dict
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
