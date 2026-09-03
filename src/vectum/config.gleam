import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import simplifile
import tom.{type Toml}
import vectum/env
import vectum/event.{type EventValue}
import vectum/filter.{type Filter, Filter}
import vectum/retry.{type Policy, Policy}
import vectum/route.{type Route, Route}

pub type Config {
  Config(
    server: ServerConfig,
    storage: StorageConfig,
    sources: List(Source),
    destinations: List(Destination),
    routes: List(Route),
    delivery: Policy,
    concurrency: Int,
  )
}

pub type ServerConfig {
  ServerConfig(host: String, port: Int, max_body_bytes: Int)
}

pub type StorageConfig {
  StorageConfig(path: String)
}

pub type Source {
  Source(
    name: String,
    path: String,
    type_from_header: Option(String),
    type_from_json: Option(String),
    type_fixed: Option(String),
    hmac_secret: Option(String),
    hmac_header: String,
  )
}

pub type Destination {
  HttpDestination(
    name: String,
    url: String,
    timeout_ms: Option(Int),
    hmac_secret: Option(String),
    hmac_header: String,
  )
}

pub type ConfigError {
  ConfigError(messages: List(String))
}

const default_hmac_source_header = "X-Hub-Signature-256"

const default_hmac_dest_header = "X-Vectum-Signature"

pub fn default_getenv(name: String) -> Result(String, Nil) {
  env.get(name)
}

pub fn load(path: String) -> Result(Config, ConfigError) {
  load_with(path, default_getenv)
}

pub fn load_with(
  path: String,
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Config, ConfigError) {
  case simplifile.read(path) {
    Ok(text) -> parse_with(text, getenv)
    Error(error) ->
      Error(
        ConfigError([
          "failed to read config " <> path <> ": " <> string.inspect(error),
        ]),
      )
  }
}

/// dead-letter 系コマンド用に `[storage] path` だけ読む。
/// webhook secret などの無関係な検証エラーで操作不能にならないようにする。
pub fn load_storage_path(path: String) -> Result(String, ConfigError) {
  case simplifile.read(path) {
    Error(error) ->
      Error(
        ConfigError([
          "failed to read config " <> path <> ": " <> string.inspect(error),
        ]),
      )
    Ok(text) -> parse_storage_path(text)
  }
}

pub fn parse_storage_path(text: String) -> Result(String, ConfigError) {
  case tom.parse(text) {
    Error(error) ->
      Error(ConfigError(["invalid TOML: " <> string.inspect(error)]))
    Ok(doc) ->
      case decode_storage(doc) {
        Ok(storage) -> Ok(storage.path)
        Error(messages) -> Error(ConfigError(messages))
      }
  }
}

pub fn parse(text: String) -> Result(Config, ConfigError) {
  parse_with(text, default_getenv)
}

pub fn parse_with(
  text: String,
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Config, ConfigError) {
  case tom.parse(text) {
    Error(error) ->
      Error(ConfigError(["invalid TOML: " <> string.inspect(error)]))
    Ok(doc) -> decode_config(doc, getenv)
  }
}

pub fn find_source(config: Config, name: String) -> Result(Source, Nil) {
  list.find(config.sources, fn(source) { source.name == name })
}

pub fn find_destination(
  config: Config,
  name: String,
) -> Result(Destination, Nil) {
  list.find(config.destinations, fn(dest) { dest.name == name })
}

pub fn destination_name(destination: Destination) -> String {
  let HttpDestination(name:, ..) = destination
  name
}

fn decode_config(
  doc: Dict(String, Toml),
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Config, ConfigError) {
  let server = decode_server(doc)
  let storage = decode_storage(doc)
  let delivery = decode_delivery(doc)
  let sources = decode_sources(doc, getenv)
  let destinations = decode_destinations(doc, getenv)
  let routes = decode_routes(doc)

  let errors =
    list.flatten([
      result_errors(server),
      result_errors(storage),
      result_errors(delivery),
      result_errors(sources),
      result_errors(destinations),
      result_errors(routes),
    ])

  case errors, server, storage, delivery, sources, destinations, routes {
    [],
      Ok(server),
      Ok(storage),
      Ok(#(policy, concurrency)),
      Ok(sources),
      Ok(destinations),
      Ok(routes)
    -> {
      let config =
        Config(
          server:,
          storage:,
          sources:,
          destinations:,
          routes:,
          delivery: policy,
          concurrency:,
        )
      case validate(config) {
        [] -> Ok(config)
        messages -> Error(ConfigError(messages))
      }
    }
    _, _, _, _, _, _, _ -> Error(ConfigError(errors))
  }
}

fn decode_server(
  doc: Dict(String, Toml),
) -> Result(ServerConfig, List(String)) {
  use host <- result.try(opt_string(doc, ["server", "host"], "0.0.0.0"))
  use port <- result.try(opt_int(doc, ["server", "port"], 8080))
  use max_body_bytes <- result.try(opt_int(
    doc,
    ["server", "max_body_bytes"],
    1_048_576,
  ))
  Ok(ServerConfig(host:, port:, max_body_bytes:))
}

fn decode_storage(
  doc: Dict(String, Toml),
) -> Result(StorageConfig, List(String)) {
  use path <- result.try(opt_string(doc, ["storage", "path"], "./router.db"))
  Ok(StorageConfig(path:))
}

fn decode_delivery(
  doc: Dict(String, Toml),
) -> Result(#(Policy, Int), List(String)) {
  use max_attempts <- result.try(opt_int(doc, ["delivery", "max_attempts"], 8))
  use initial_backoff_ms <- result.try(opt_int(
    doc,
    ["delivery", "initial_backoff_ms"],
    1000,
  ))
  use max_backoff_ms <- result.try(opt_int(
    doc,
    ["delivery", "max_backoff_ms"],
    60_000,
  ))
  use timeout_ms <- result.try(opt_int(doc, ["delivery", "timeout_ms"], 10_000))
  use jitter <- result.try(opt_bool(doc, ["delivery", "jitter"], True))
  use concurrency <- result.try(opt_int(doc, ["delivery", "concurrency"], 8))
  Ok(#(
    Policy(
      max_attempts:,
      initial_backoff_ms:,
      max_backoff_ms:,
      timeout_ms:,
      jitter:,
    ),
    concurrency,
  ))
}

fn decode_sources(
  doc: Dict(String, Toml),
  getenv: fn(String) -> Result(String, Nil),
) -> Result(List(Source), List(String)) {
  use tables <- result.try(get_tables(doc, "sources"))
  map_collect(tables, fn(table) { decode_source(table, getenv) })
}

fn decode_source(
  table: Dict(String, Toml),
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Source, List(String)) {
  use name <- result.try(req_string(table, ["name"]))
  use path <- result.try(opt_string(table, ["path"], "/events/" <> name))
  use type_from_header <- result.try(
    opt_string_opt(table, ["type_from_header"]),
  )
  use type_from_json <- result.try(opt_string_opt(table, ["type_from_json"]))
  use type_fixed <- result.try(opt_string_opt(table, ["type_fixed"]))
  use hmac_header <- result.try(opt_string(
    table,
    ["hmac_header"],
    default_hmac_source_header,
  ))
  use hmac_secret <- result.try(resolve_secret(table, name, "source", getenv))
  Ok(Source(
    name:,
    path:,
    type_from_header:,
    type_from_json:,
    type_fixed:,
    hmac_secret:,
    hmac_header:,
  ))
}

fn decode_destinations(
  doc: Dict(String, Toml),
  getenv: fn(String) -> Result(String, Nil),
) -> Result(List(Destination), List(String)) {
  use tables <- result.try(get_tables(doc, "destinations"))
  map_collect(tables, fn(table) { decode_destination(table, getenv) })
}

fn decode_destination(
  table: Dict(String, Toml),
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Destination, List(String)) {
  use name <- result.try(req_string(table, ["name"]))
  use dest_type <- result.try(opt_string(table, ["type"], "http"))
  use url <- result.try(req_string(table, ["url"]))
  use timeout_ms <- result.try(opt_int_opt(table, ["timeout_ms"]))
  use hmac_header <- result.try(opt_string(
    table,
    ["hmac_header"],
    default_hmac_dest_header,
  ))
  use hmac_secret <- result.try(resolve_secret(
    table,
    name,
    "destination",
    getenv,
  ))
  case dest_type {
    "http" ->
      Ok(HttpDestination(name:, url:, timeout_ms:, hmac_secret:, hmac_header:))
    other ->
      Error([
        "destination " <> name <> " has unsupported adapter type: " <> other,
      ])
  }
}

fn decode_routes(doc: Dict(String, Toml)) -> Result(List(Route), List(String)) {
  use tables <- result.try(get_tables(doc, "routes"))
  map_collect(tables, decode_route)
}

fn decode_route(table: Dict(String, Toml)) -> Result(Route, List(String)) {
  use name <- result.try(req_string(table, ["name"]))
  use source <- result.try(req_string(table, ["source"]))
  use event <- result.try(req_string(table, ["event"]))
  use destinations <- result.try(req_string_list(table, ["destinations"]))
  use filters <- result.try(decode_filters(table, name))
  Ok(Route(name:, source:, event:, destinations:, filters:))
}

fn decode_filters(
  table: Dict(String, Toml),
  route_name: String,
) -> Result(List(Filter), List(String)) {
  case tom.get(table, ["filters"]) {
    Error(tom.NotFound(_)) -> Ok([])
    Ok(tom.ArrayOfTables(tables)) ->
      map_collect(tables, fn(filter_table) {
        decode_filter(filter_table, route_name)
      })
    Ok(tom.Array(items)) ->
      map_collect(items, fn(item) {
        case item {
          tom.Table(inner) | tom.InlineTable(inner) ->
            decode_filter(inner, route_name)
          _ -> Error(["route " <> route_name <> " filters must be tables"])
        }
      })
    Ok(_) -> Error(["route " <> route_name <> " filters must be an array"])
    Error(tom.WrongType(_, expected, got)) ->
      Error([
        "route "
        <> route_name
        <> " filters must be "
        <> expected
        <> ", got "
        <> got,
      ])
  }
}

fn decode_filter(
  table: Dict(String, Toml),
  route_name: String,
) -> Result(Filter, List(String)) {
  use path <- result.try(req_string(table, ["path"]))
  use op_name <- result.try(req_string(table, ["op"]))
  use op <- result.try(
    filter.parse_op(op_name)
    |> result.map_error(fn(message) {
      ["route " <> route_name <> ": " <> message]
    }),
  )
  use value <- result.try(case op {
    filter.Exists | filter.NotExists ->
      case tom.get(table, ["value"]) {
        Error(tom.NotFound(_)) -> Ok(event.Null)
        Ok(toml) -> toml_value(toml)
        Error(tom.WrongType(_, expected, got)) ->
          Error(["filter value must be " <> expected <> ", got " <> got])
      }
    _ ->
      case tom.get(table, ["value"]) {
        Error(tom.NotFound(_)) ->
          Error([
            "route " <> route_name <> " filter " <> path <> " requires value",
          ])
        Ok(toml) -> toml_value(toml)
        Error(tom.WrongType(_, expected, got)) ->
          Error(["filter value must be " <> expected <> ", got " <> got])
      }
  })
  Ok(Filter(path:, op:, value:))
}

fn toml_value(toml: Toml) -> Result(EventValue, List(String)) {
  case toml {
    tom.String(text) -> Ok(event.String(text))
    tom.Int(n) -> Ok(event.Int(n))
    tom.Float(n) -> Ok(event.Float(n))
    tom.Bool(flag) -> Ok(event.Bool(flag))
    _ -> Error(["unsupported filter value type"])
  }
}

fn resolve_secret(
  table: Dict(String, Toml),
  name: String,
  kind: String,
  getenv: fn(String) -> Result(String, Nil),
) -> Result(Option(String), List(String)) {
  use inline <- result.try(opt_string_opt(table, ["hmac_secret"]))
  use env_name <- result.try(opt_string_opt(table, ["hmac_secret_env"]))
  // inline と env 参照の併設は意図が曖昧なため拒否する。
  // 空文字の secret は検証鍵として無意味なため拒否する。
  case inline, env_name {
    Some(_), Some(var) ->
      Error([
        kind
        <> " "
        <> name
        <> " sets both hmac_secret and hmac_secret_env ("
        <> var
        <> "); use only one",
      ])
    _, Some(var) ->
      case getenv(var) {
        Ok(value) ->
          case string.trim(value) {
            "" ->
              Error([
                kind
                <> " "
                <> name
                <> " references empty environment variable "
                <> var,
              ])
            _ -> Ok(Some(value))
          }
        Error(_) ->
          Error([
            kind
            <> " "
            <> name
            <> " references missing environment variable "
            <> var,
          ])
      }
    Some(value), None ->
      case string.trim(value) {
        "" -> Error([kind <> " " <> name <> " has empty hmac_secret"])
        _ -> Ok(Some(value))
      }
    None, None -> Ok(None)
  }
}

fn result_errors(result: Result(a, List(String))) -> List(String) {
  case result {
    Error(messages) -> messages
    Ok(_) -> []
  }
}

fn validate(config: Config) -> List(String) {
  list.flatten([
    validate_server(config.server),
    validate_delivery(config.delivery, config.concurrency),
    duplicate_names(
      list.map(config.sources, fn(source) { source.name }),
      "source",
    ),
    duplicate_names(
      list.map(config.destinations, destination_name),
      "destination",
    ),
    duplicate_names(list.map(config.routes, fn(route) { route.name }), "route"),
    reject_empty_names(
      list.map(config.sources, fn(source) { source.name }),
      "source",
    ),
    reject_empty_names(
      list.map(config.destinations, destination_name),
      "destination",
    ),
    reject_empty_names(
      list.map(config.routes, fn(route) { route.name }),
      "route",
    ),
    list.flat_map(config.sources, validate_source),
    list.flat_map(config.destinations, validate_destination),
    list.flat_map(config.routes, fn(route) {
      validate_route(route, config.sources, config.destinations)
    }),
  ])
}

fn validate_server(server: ServerConfig) -> List(String) {
  let port = case server.port >= 1 && server.port <= 65_535 {
    True -> []
    False -> ["server.port must be between 1 and 65535"]
  }
  let body = case server.max_body_bytes >= 1 {
    True -> []
    False -> ["server.max_body_bytes must be >= 1"]
  }
  list.append(port, body)
}

fn validate_delivery(policy: Policy, concurrency: Int) -> List(String) {
  [
    require_positive(policy.max_attempts, "delivery.max_attempts"),
    require_positive(policy.initial_backoff_ms, "delivery.initial_backoff_ms"),
    require_positive(policy.max_backoff_ms, "delivery.max_backoff_ms"),
    require_positive(policy.timeout_ms, "delivery.timeout_ms"),
    require_positive(concurrency, "delivery.concurrency"),
    case policy.initial_backoff_ms <= policy.max_backoff_ms {
      True -> None
      False ->
        Some("delivery.initial_backoff_ms must be <= delivery.max_backoff_ms")
    },
  ]
  |> option.values
}

fn validate_source(source: Source) -> List(String) {
  // source 名は POST /events/:source の単一パス要素と照合される。
  // 空や `/` 含みは到達不能な定義になるため config 時に落とす。
  let name_errors = case source.name {
    "" -> ["source name must not be empty"]
    _ ->
      case string.contains(source.name, "/") {
        True -> [
          "source \""
          <> source.name
          <> "\" must not contain '/' (POST /events/:source is a single path segment)",
        ]
        False -> []
      }
  }
  let type_errors = case
    source.type_from_header,
    source.type_from_json,
    source.type_fixed
  {
    None, None, None -> [
      "source "
      <> source.name
      <> " must set type_from_header, type_from_json, or type_fixed",
    ]
    _, _, _ -> []
  }
  list.append(name_errors, type_errors)
}

fn validate_destination(destination: Destination) -> List(String) {
  let HttpDestination(name:, url:, timeout_ms:, ..) = destination
  let url_errors = case uri.parse(url) {
    Error(_) -> ["destination " <> name <> " has invalid URL"]
    Ok(parsed) ->
      case parsed.scheme, parsed.host {
        Some("http"), Some(_) | Some("https"), Some(_) -> []
        Some(scheme), _ -> [
          "destination "
          <> name
          <> " has invalid URL: scheme must be http or https, got "
          <> scheme,
        ]
        None, _ -> ["destination " <> name <> " has invalid URL"]
      }
  }
  let timeout_errors = case timeout_ms {
    None -> []
    Some(ms) if ms >= 1 -> []
    Some(_) -> ["destination " <> name <> " timeout_ms must be >= 1"]
  }
  list.append(url_errors, timeout_errors)
}

fn validate_route(
  route: Route,
  sources: List(Source),
  destinations: List(Destination),
) -> List(String) {
  let source_ok = list.any(sources, fn(source) { source.name == route.source })
  let source_error = case source_ok {
    True -> []
    False -> [
      "route " <> route.name <> " references unknown source " <> route.source,
    ]
  }
  let empty_error = case route.destinations {
    [] -> ["route " <> route.name <> " must list at least one destination"]
    _ -> []
  }
  let dest_errors =
    list.filter_map(route.destinations, fn(dest) {
      case list.any(destinations, fn(item) { destination_name(item) == dest }) {
        True -> Error(Nil)
        False ->
          Ok(
            "route " <> route.name <> " references unknown destination " <> dest,
          )
      }
    })
  list.append(source_error, list.append(empty_error, dest_errors))
}

/// 空・空白のみの name を拒否する。空 source 名は到達不能、
/// 空 route/destination 名は参照解決を曖昧にするため。
fn reject_empty_names(names: List(String), kind: String) -> List(String) {
  case list.any(names, fn(name) { string.trim(name) == "" }) {
    True -> [kind <> " name must not be empty"]
    False -> []
  }
}

fn duplicate_names(names: List(String), kind: String) -> List(String) {
  let #(_seen, dups) =
    list.fold(names, #(dict.new(), []), fn(acc, name) {
      let #(seen, dups) = acc
      case dict.get(seen, name) {
        Ok(_) -> #(seen, ["duplicate " <> kind <> " name: " <> name, ..dups])
        Error(_) -> #(dict.insert(seen, name, True), dups)
      }
    })
  list.reverse(dups)
}

fn require_positive(value: Int, label: String) -> Option(String) {
  case value >= 1 {
    True -> None
    False -> Some(label <> " must be >= 1")
  }
}

fn get_tables(
  doc: Dict(String, Toml),
  key: String,
) -> Result(List(Dict(String, Toml)), List(String)) {
  case tom.get(doc, [key]) {
    Error(tom.NotFound(_)) -> Ok([])
    Ok(tom.ArrayOfTables(tables)) -> Ok(tables)
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.Table(table) | tom.InlineTable(table) -> Ok(table)
          _ -> Error(Nil)
        }
      })
      |> result.map_error(fn(_) { [key <> " must be an array of tables"] })
    Ok(_) -> Error([key <> " must be an array of tables"])
    Error(tom.WrongType(_, expected, got)) ->
      Error([key <> " must be " <> expected <> ", got " <> got])
  }
}

fn req_string(
  table: Dict(String, Toml),
  key: List(String),
) -> Result(String, List(String)) {
  case tom.get_string(table, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Error(["missing " <> key_label(key)])
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn opt_string(
  table: Dict(String, Toml),
  key: List(String),
  default: String,
) -> Result(String, List(String)) {
  case tom.get_string(table, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn opt_string_opt(
  table: Dict(String, Toml),
  key: List(String),
) -> Result(Option(String), List(String)) {
  case tom.get_string(table, key) {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn opt_int(
  table: Dict(String, Toml),
  key: List(String),
  default: Int,
) -> Result(Int, List(String)) {
  case tom.get_int(table, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn opt_int_opt(
  table: Dict(String, Toml),
  key: List(String),
) -> Result(Option(Int), List(String)) {
  case tom.get_int(table, key) {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn opt_bool(
  table: Dict(String, Toml),
  key: List(String),
  default: Bool,
) -> Result(Bool, List(String)) {
  case tom.get_bool(table, key) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
  }
}

fn req_string_list(
  table: Dict(String, Toml),
  key: List(String),
) -> Result(List(String), List(String)) {
  case tom.get_array(table, key) {
    Error(tom.NotFound(_)) -> Error(["missing " <> key_label(key)])
    Error(tom.WrongType(_, expected, got)) ->
      Error([key_label(key) <> " must be " <> expected <> ", got " <> got])
    Ok(items) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error(Nil)
        }
      })
      |> result.map_error(fn(_) {
        [key_label(key) <> " must be an array of strings"]
      })
  }
}

fn map_collect(
  items: List(a),
  fun: fn(a) -> Result(b, List(String)),
) -> Result(List(b), List(String)) {
  let #(oks, errors) =
    list.fold(items, #([], []), fn(acc, item) {
      let #(oks, errors) = acc
      case fun(item) {
        Ok(value) -> #([value, ..oks], errors)
        Error(messages) -> #(oks, list.append(errors, messages))
      }
    })
  case errors {
    [] -> Ok(list.reverse(oks))
    _ -> Error(errors)
  }
}

fn key_label(key: List(String)) -> String {
  string.join(key, ".")
}
