//// Issue #45: chunked リクエストで max_body_bytes を突破できないことを
//// HTTP レベルで確認するテスト。

import gleam/bit_array
import gleam/erlang/process
import gleam/string
import mist
import vectum/config
import vectum/ingress
import vectum/metrics
import vectum/storage

@external(erlang, "http_ffi", "request")
fn raw_request(
  host: String,
  port: Int,
  data: BitArray,
  timeout_ms: Int,
) -> BitArray

const toml = "
[server]
max_body_bytes = 64

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
"

const host = "127.0.0.1"

fn start_server(port: Int) -> Nil {
  let assert Ok(store) = storage.start(":memory:")
  let assert Ok(metrics) = metrics.start()
  let assert Ok(parsed) = config.parse_with(toml, fn(_) { Error(Nil) })
  let assert Ok(_) =
    ingress.service(parsed, store, metrics)
    |> mist.new
    |> mist.bind(host)
    |> mist.port(port)
    |> mist.start
  process.sleep(100)
}

fn send(port: Int, request: String) -> String {
  raw_request(host, port, bit_array.from_string(request), 5000)
  |> bit_array.to_string
  |> fn(result) {
    let assert Ok(body) = result
    body
  }
}

pub fn chunked_request_is_rejected_test() {
  let port = 18_971
  start_server(port)
  // transfer-encoding: chunked は mist.read_body が上限を適用できないため
  // サイズに関係なく 413 で拒否される
  let response =
    send(
      port,
      "POST /events/internal HTTP/1.1\r\n"
        <> "Host: "
        <> host
        <> "\r\n"
        <> "Content-Type: application/json\r\n"
        <> "Transfer-Encoding: chunked\r\n"
        <> "Connection: close\r\n"
        <> "\r\n"
        <> "5\r\nhello\r\n"
        <> "0\r\n\r\n",
    )
  assert string.contains(response, "413")
}

pub fn oversized_body_is_rejected_test() {
  let port = 18_972
  start_server(port)
  // Content-Length 付きの既存 413 経路が維持されていること
  let body = string.repeat("a", 100)
  let response =
    send(
      port,
      "POST /events/internal HTTP/1.1\r\n"
        <> "Host: "
        <> host
        <> "\r\n"
        <> "Content-Type: application/json\r\n"
        <> "Content-Length: 100\r\n"
        <> "Connection: close\r\n"
        <> "\r\n"
        <> body,
    )
  assert string.contains(response, "413")
}

pub fn normal_request_is_accepted_test() {
  let port = 18_973
  start_server(port)
  let body = "{\"type\":\"ping\",\"n\":1}"
  let response =
    send(
      port,
      "POST /events/internal HTTP/1.1\r\n"
        <> "Host: "
        <> host
        <> "\r\n"
        <> "Content-Type: application/json\r\n"
        <> "Content-Length: "
        <> int_to_string(string.byte_size(body))
        <> "\r\n"
        <> "Connection: close\r\n"
        <> "\r\n"
        <> body,
    )
  assert string.contains(response, "202")
}

fn int_to_string(n: Int) -> String {
  string.inspect(n)
}
