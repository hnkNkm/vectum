import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import vectum/config
import vectum/event
import vectum/filter

const valid = "
[server]
host = \"127.0.0.1\"
port = 8080

[storage]
path = \":memory:\"

[[sources]]
name = \"github\"
path = \"/events/github\"
type_from_header = \"X-GitHub-Event\"
hmac_secret = \"whsec\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"ci\"
type = \"http\"
url = \"http://127.0.0.1:9091/events\"
timeout_ms = 5000

[[destinations]]
name = \"audit\"
url = \"https://audit.internal/events\"
hmac_secret_env = \"AUDIT_SECRET\"

[[routes]]
name = \"github-push\"
source = \"github\"
event = \"push\"
destinations = [\"ci\", \"audit\"]

[[routes]]
name = \"backend-pr\"
source = \"github\"
event = \"pull_request\"
destinations = [\"audit\"]

[[routes.filters]]
path = \"repository.name\"
op = \"eq\"
value = \"backend\"

[delivery]
max_attempts = 4
jitter = false
"

fn getenv(name: String) -> Result(String, Nil) {
  dict.get(dict.from_list([#("AUDIT_SECRET", "dest-secret")]), name)
}

pub fn parse_valid_config_test() {
  let assert Ok(parsed) = config.parse_with(valid, getenv)
  assert parsed.server.host == "127.0.0.1"
  assert parsed.server.port == 8080
  assert parsed.storage.path == ":memory:"
  assert parsed.delivery.max_attempts == 4
  assert parsed.delivery.jitter == False
  assert parsed.concurrency == 8

  let assert Ok(github) = config.find_source(parsed, "github")
  assert github.path == "/events/github"
  assert github.hmac_secret == Some("whsec")
  assert github.hmac_header == "X-Hub-Signature-256"

  let assert Ok(internal) = config.find_source(parsed, "internal")
  assert internal.path == "/events/internal"
  assert internal.type_from_json == Some("type")

  let assert Ok(config.HttpDestination(
    name: "audit",
    hmac_secret: Some("dest-secret"),
    ..,
  )) = config.find_destination(parsed, "audit")

  let assert Ok(pr) =
    list.find(parsed.routes, fn(route) { route.name == "backend-pr" })
  assert pr.filters
    == [
      filter.Filter(
        path: "repository.name",
        op: filter.Eq,
        value: event.String("backend"),
      ),
    ]
}

pub fn unknown_destination_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
[[routes]]
name = \"r\"
source = \"s\"
event = \"ping\"
destinations = [\"missing\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "unknown destination") })
}

pub fn unknown_source_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
[[routes]]
name = \"r\"
source = \"nope\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "unknown source") })
}

pub fn duplicate_names_are_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[sources]]
name = \"s\"
type_fixed = \"pong\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "duplicate source") })
}

pub fn invalid_filter_operator_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
[[routes]]
name = \"r\"
source = \"s\"
event = \"ping\"
destinations = [\"ok\"]
[[routes.filters]]
path = \"a\"
op = \"regex\"
value = \"x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "invalid filter") })
}

pub fn invalid_url_and_adapter_are_rejected_test() {
  let bad_url =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"not-a-url\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(bad_url, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "invalid URL") })

  let mqtt =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
type = \"mqtt\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(mqtt_messages)) =
    config.parse_with(mqtt, getenv)
  assert list.any(mqtt_messages, fn(m) {
    string.contains(m, "unsupported adapter")
  })
}

pub fn missing_env_var_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret_env = \"MISSING_SECRET\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "MISSING_SECRET") })
}

pub fn invalid_retry_values_are_rejected_test() {
  let toml =
    "
[delivery]
max_attempts = 0
timeout_ms = -1
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "max_attempts") })
}

pub fn empty_inline_secret_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret = \"\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "empty hmac_secret") })
}

pub fn blank_inline_secret_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret = \"   \"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "empty hmac_secret") })
}

pub fn empty_env_secret_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret_env = \"EMPTY_SECRET\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, fn(name) {
      case name {
        "EMPTY_SECRET" -> Ok("")
        _ -> Error(Nil)
      }
    })
  assert list.any(messages, fn(m) { string.contains(m, "empty hmac_secret") })
}

pub fn both_secret_kinds_are_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret = \"inline\"
hmac_secret_env = \"AUDIT_SECRET\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "both hmac_secret and hmac_secret_env")
  })
}

pub fn empty_hmac_header_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret = \"sec\"
hmac_header = \"\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "hmac_header must not be empty")
  })
}

pub fn example_config_requires_env_test() {
  let assert Error(config.ConfigError(messages)) =
    config.load_with("examples/router.toml", fn(_) { Error(Nil) })
  assert list.any(messages, fn(m) { string.contains(m, "environment variable") })
}
