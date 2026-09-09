//// HTTP-level ingress tests (#45): raw TCP through a real mist server.
//// Proves chunked bodies cannot bypass `max_body_bytes`.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import mist
import vectum/config
import vectum/ingress
import vectum/metrics
import vectum/storage

@external(erlang, "http_ffi", "send_raw")
fn send_raw(port: Int, packet: BitArray) -> BitArray

const toml = "
[server]
host = \"127.0.0.1\"
port = 18771
max_body_bytes = 32

[storage]
path = \":memory:\"

[[sources]]
name = \"internal\"
type_from_json = \"type\"

[[destinations]]
name = \"audit\"
url = \"http://127.0.0.1:9/events\"

[[routes]]
name = \"all\"
source = \"internal\"
event = \"*\"
destinations = [\"audit\"]

[delivery]
jitter = false
"

fn started_server(port: Int) -> Int {
  started_server_with(toml, port)
}

fn started_server_with(toml: String, port: Int) -> Int {
  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(m) = metrics.start()
  let assert Ok(_) =
    ingress.service(parsed, store, m)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  // listen の完了を待つ
  process.sleep(200)
  port
}

fn status_line(response: BitArray) -> String {
  let text = case bit_array.to_string(response) {
    Ok(text) -> text
    Error(_) -> ""
  }
  case string.split(text, "\r\n") {
    [first, ..] -> first
    [] -> text
  }
}

fn chunked_packet(body: String) -> BitArray {
  bit_array.from_string(
    "POST /events/internal HTTP/1.1\r\n"
    <> "host: 127.0.0.1\r\n"
    <> "content-type: application/json\r\n"
    <> "transfer-encoding: chunked\r\n"
    <> "connection: close\r\n"
    <> "\r\n"
    // 64 bytes
    <> "40\r\n"
    <> body
    <> "\r\n0\r\n\r\n",
  )
}

fn content_length_packet(body: String) -> BitArray {
  content_length_packet_to("/events/internal", body)
}

fn content_length_packet_to(path: String, body: String) -> BitArray {
  bit_array.from_string(
    "POST "
    <> path
    <> " HTTP/1.1\r\n"
    <> "host: 127.0.0.1\r\n"
    <> "content-type: application/json\r\n"
    <> "content-length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n"
    <> "connection: close\r\n"
    <> "\r\n"
    <> body,
  )
}

// Task C: sources.path をそのまま受信パスとして照合する。
const custom_toml = "
[server]
host = \"127.0.0.1\"
port = 18780
max_body_bytes = 1024

[storage]
path = \":memory:\"

[[sources]]
name = \"webhook\"
path = \"/hooks/github\"
type_from_json = \"type\"

[[sources]]
name = \"defaulted\"
type_from_json = \"type\"

[[destinations]]
name = \"audit\"
url = \"http://127.0.0.1:9/events\"

[[routes]]
name = \"webhook-all\"
source = \"webhook\"
event = \"*\"
destinations = [\"audit\"]

[[routes]]
name = \"defaulted-all\"
source = \"defaulted\"
event = \"*\"
destinations = [\"audit\"]

[delivery]
jitter = false
"

pub fn chunked_body_over_limit_is_rejected_test() {
  let port = started_server(18_771)
  // 64 bytes of chunked body against max_body_bytes = 32
  let body = string.join(list.repeat("x", 64), "")
  let response = send_raw(port, chunked_packet(body))
  assert string.starts_with(status_line(response), "HTTP/1.1 413")
}

pub fn content_length_over_limit_is_rejected_test() {
  let port = started_server(18_772)
  let body = string.join(list.repeat("x", 64), "")
  let response = send_raw(port, content_length_packet(body))
  assert string.starts_with(status_line(response), "HTTP/1.1 413")
}

pub fn small_body_is_accepted_test() {
  let port = started_server(18_773)
  let body = "{\"type\":\"ping\"}"
  let response = send_raw(port, content_length_packet(body))
  assert string.starts_with(status_line(response), "HTTP/1.1 202")
}

// --- Task C: custom sources.path routing (#39) ---

pub fn custom_path_receives_post_is_202_test() {
  let port = started_server_with(custom_toml, 18_780)
  let body = "{\"type\":\"push\"}"
  let response = send_raw(port, content_length_packet_to("/hooks/github", body))
  assert string.starts_with(status_line(response), "HTTP/1.1 202")
}

pub fn default_path_source_still_works_test() {
  // path 未設定の source は引き続き POST /events/<name> で受ける。
  let port = started_server_with(custom_toml, 18_781)
  let body = "{\"type\":\"push\"}"
  let response =
    send_raw(port, content_length_packet_to("/events/defaulted", body))
  assert string.starts_with(status_line(response), "HTTP/1.1 202")
}

pub fn unknown_path_is_404_test() {
  let port = started_server_with(custom_toml, 18_782)
  let body = "{\"type\":\"push\"}"
  let response = send_raw(port, content_length_packet_to("/nope", body))
  assert string.starts_with(status_line(response), "HTTP/1.1 404")
}

pub fn custom_source_default_path_is_not_routed_test() {
  // custom path source は既定 /events/<name> では受け付けない。
  let port = started_server_with(custom_toml, 18_783)
  let body = "{\"type\":\"push\"}"
  let response =
    send_raw(port, content_length_packet_to("/events/webhook", body))
  assert string.starts_with(status_line(response), "HTTP/1.1 404")
}
