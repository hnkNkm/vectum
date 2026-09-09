import gleam/dict
import gleam/list
import gleam/option.{None, Some}
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

  // 既知キーのみの構成では警告が出ないこと (Task B)
  assert parsed.warnings == []

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
  assert pr.condition == None
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

pub fn example_config_requires_env_test() {
  let assert Error(config.ConfigError(messages)) =
    config.load_with("examples/router.toml", fn(_) { Error(Nil) })
  assert list.any(messages, fn(m) { string.contains(m, "environment variable") })
}

pub fn empty_destinations_are_rejected_test() {
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
destinations = []
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "at least one destination")
  })
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
[[routes]]
name = \"r\"
source = \"s\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "empty hmac_secret") })
}

pub fn both_secrets_are_rejected_test() {
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
[[routes]]
name = \"r\"
source = \"s\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "both hmac_secret") })
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
[[routes]]
name = \"r\"
source = \"s\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, fn(_) { Ok("") })
  assert list.any(messages, fn(m) {
    string.contains(m, "empty environment variable")
  })
}

pub fn slash_source_name_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"a/b\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
[[routes]]
name = \"r\"
source = \"a/b\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "must not contain") })
}

pub fn storage_path_loads_without_full_validation_test() {
  // secret 欠落で full load は失敗するが、storage path だけは読める。
  let toml =
    "
[storage]
path = \"/data/router.db\"
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_secret_env = \"MISSING_SECRET\"
"
  let assert Error(_) = config.parse_with(toml, getenv)
  let assert Ok(path) = config.parse_storage_path(toml)
  assert path == "/data/router.db"
}

pub fn empty_route_name_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
[[routes]]
name = \"\"
source = \"s\"
event = \"ping\"
destinations = [\"ok\"]
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "route name must not be empty")
  })
}

// --- Task A: hmac_header の空・空白 reject ---

pub fn empty_source_hmac_header_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_header = \"\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "hmac_header") })
}

pub fn blank_source_hmac_header_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
hmac_header = \"   \"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "hmac_header") })
}

pub fn empty_destination_hmac_header_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
hmac_header = \"\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "hmac_header") })
}

pub fn blank_destination_hmac_header_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
hmac_header = \"  \"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "hmac_header") })
}

// --- Task B: 未知キーは warn のみで失敗しない ---

pub fn unknown_server_key_is_warned_not_rejected_test() {
  let toml =
    "
[server]
host = \"127.0.0.1\"
bogus_server_key = true
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in [server]")
    && string.contains(w, "bogus_server_key")
  })
}

pub fn unknown_source_key_is_warned_not_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
bogus_source_key = 1
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in source s")
    && string.contains(w, "bogus_source_key")
  })
}

pub fn unknown_destination_key_is_warned_not_rejected_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
bogus_dest_key = \"x\"
"
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in destination ok")
    && string.contains(w, "bogus_dest_key")
  })
}

pub fn unknown_filter_key_is_warned_not_rejected_test() {
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
op = \"eq\"
value = \"x\"
bogus_filter_key = true
"
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in route r filters")
    && string.contains(w, "bogus_filter_key")
  })
}

// --- Task C: sources.path の検証 ---

pub fn source_path_default_is_events_name_test() {
  let toml =
    "
[[sources]]
name = \"no-path\"
type_fixed = \"ping\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  let assert Ok(src) = config.find_source(parsed, "no-path")
  assert src.path == "/events/no-path"
}

pub fn source_path_must_start_with_slash_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
path = \"hooks/gh\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "must start with '/'") })
}

pub fn source_path_must_not_be_root_test() {
  let toml =
    "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
path = \"/\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "must not be '/'") })
}

pub fn source_path_forbids_query_fragment_whitespace_test() {
  let bad = fn(path: String) -> Bool {
    let toml = "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
path = \"" <> path <> "\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
    let assert Error(config.ConfigError(messages)) =
      config.parse_with(toml, getenv)
    list.any(messages, fn(m) {
      string.contains(m, "must not contain '?', '#' or whitespace")
    })
  }
  assert bad("/hooks?x=1")
  assert bad("/hooks#frag")
  assert bad("/hooks with space")
}

pub fn duplicate_source_path_is_rejected_test() {
  let toml =
    "
[[sources]]
name = \"a\"
type_fixed = \"ping\"
path = \"/same\"
[[sources]]
name = \"b\"
type_fixed = \"pong\"
path = \"/same\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "duplicate source path")
  })
}

pub fn default_path_colliding_with_custom_path_is_rejected_test() {
  // b の既定パス /events/b と、a の明示 /events/b が衝突する
  let toml =
    "
[[sources]]
name = \"b\"
type_fixed = \"ping\"
[[sources]]
name = \"a\"
type_fixed = \"pong\"
path = \"/events/b\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "duplicate source path")
  })
}

pub fn source_path_must_not_collide_with_reserved_test() {
  let paths = ["/health", "/ready", "/metrics"]
  assert list.all(paths, fn(path) {
    let toml = "
[[sources]]
name = \"s\"
type_fixed = \"ping\"
path = \"" <> path <> "\"
[[destinations]]
name = \"ok\"
url = \"http://127.0.0.1/x\"
"
    let assert Error(config.ConfigError(messages)) =
      config.parse_with(toml, getenv)
    list.any(messages, fn(m) { string.contains(m, "reserved ingress endpoint") })
  })
}

// --- Task #36: grouped condition(routes.condition) ---

/// ルートの参照元が揃った最小 TOML の雛形。body に route 本体以降を足す。
fn condition_toml(body: String) -> String {
  "
[[sources]]
name = \"github\"
type_fixed = \"ping\"
[[destinations]]
name = \"out\"
url = \"http://127.0.0.1/x\"
" <> body
}

pub fn grouped_condition_decodes_test() {
  let toml =
    condition_toml(
      "
[[routes]]
name = \"critical\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"any\"
filters = [
  { op = \"all\", filters = [
    { path = \"severity\", op = \"eq\", value = \"critical\" },
    { path = \"retries\", op = \"gte\", value = 3 },
    { path = \"metadata.x-region\", op = \"eq\", value = \"jp\" },
  ] },
  { path = \"source\", op = \"exists\" },
  { path = \"nope\", op = \"not_exists\" },
]
",
    )
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  // 既知キーのみの構成では警告が出ないこと(condition / 各ノードのキー)
  assert parsed.warnings == []
  let assert Ok(route) =
    list.find(parsed.routes, fn(route) { route.name == "critical" })
  assert route.filters == []
  let expected =
    filter.Condition(op: filter.Any, children: [
      filter.Group(
        filter.Condition(op: filter.All, children: [
          filter.Leaf(filter.Filter(
            path: "severity",
            op: filter.Eq,
            value: event.String("critical"),
          )),
          filter.Leaf(filter.Filter(
            path: "retries",
            op: filter.Gte,
            value: event.Int(3),
          )),
          filter.Leaf(filter.Filter(
            path: "metadata.x-region",
            op: filter.Eq,
            value: event.String("jp"),
          )),
        ]),
      ),
      // exists / not_exists は value 省略可(従来の filter と同じ規則)
      filter.Leaf(filter.Filter(
        path: "source",
        op: filter.Exists,
        value: event.Null,
      )),
      filter.Leaf(filter.Filter(
        path: "nope",
        op: filter.NotExists,
        value: event.Null,
      )),
    ])
  assert route.condition == Some(expected)
}

pub fn filters_and_condition_are_mutually_exclusive_test() {
  let toml =
    condition_toml(
      "
[[routes]]
name = \"r\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[[routes.filters]]
path = \"a\"
op = \"eq\"
value = \"x\"

[routes.condition]
op = \"all\"
filters = [
  { path = \"b\", op = \"eq\", value = \"y\" },
]
",
    )
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "sets both filters and condition")
  })
}

pub fn condition_group_depth_limit_is_enforced_test() {
  // root(1 段)+ 4 段まで OK。5 段目でエラー。
  let valid =
    condition_toml(
      "
[[routes]]
name = \"deep-ok\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"all\"
filters = [
  { op = \"all\", filters = [
    { op = \"all\", filters = [
      { op = \"all\", filters = [
        { path = \"a\", op = \"eq\", value = \"x\" },
      ] },
    ] },
  ] },
]
",
    )
  let assert Ok(_) = config.parse_with(valid, getenv)

  let too_deep =
    condition_toml(
      "
[[routes]]
name = \"too-deep\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"all\"
filters = [
  { op = \"all\", filters = [
    { op = \"all\", filters = [
      { op = \"all\", filters = [
        { op = \"all\", filters = [
          { path = \"a\", op = \"eq\", value = \"x\" },
        ] },
      ] },
    ] },
  ] },
]
",
    )
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(too_deep, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "maximum condition nesting depth")
  })
}

pub fn empty_condition_group_is_rejected_test() {
  let toml =
    condition_toml(
      "
[[routes]]
name = \"r\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"any\"
filters = []
",
    )
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "must not be empty") })
}

pub fn unknown_condition_group_op_is_rejected_test() {
  let toml =
    condition_toml(
      "
[[routes]]
name = \"r\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"xor\"
filters = [
  { path = \"a\", op = \"eq\", value = \"x\" },
]
",
    )
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(toml, getenv)
  assert list.any(messages, fn(m) {
    string.contains(m, "invalid condition operator")
  })
}

pub fn condition_leaf_requires_value_unless_exists_test() {
  let missing =
    condition_toml(
      "
[[routes]]
name = \"r\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"all\"
filters = [
  { path = \"a\", op = \"eq\" },
]
",
    )
  let assert Error(config.ConfigError(messages)) =
    config.parse_with(missing, getenv)
  assert list.any(messages, fn(m) { string.contains(m, "requires value") })
}

pub fn unknown_condition_key_is_warned_not_rejected_test() {
  let toml =
    condition_toml(
      "
[[routes]]
name = \"r\"
source = \"github\"
event = \"*\"
destinations = [\"out\"]

[routes.condition]
op = \"any\"
bogus_group_key = true
filters = [
  { path = \"a\", op = \"eq\", value = \"x\", bogus_leaf_key = 1 },
]
",
    )
  let assert Ok(parsed) = config.parse_with(toml, getenv)
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in route r condition")
    && string.contains(w, "bogus_group_key")
  })
  assert list.any(parsed.warnings, fn(w) {
    string.contains(w, "unknown config key in route r condition filters[1]")
    && string.contains(w, "bogus_leaf_key")
  })
}
