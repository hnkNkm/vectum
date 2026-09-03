import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/set
import gleam/string
import vectum/event.{type Event}
import vectum/filter.{type Filter}

pub type Route {
  Route(
    name: String,
    source: String,
    event: String,
    destinations: List(String),
    filters: List(Filter),
  )
}

/// Collect matching destinations. Same Event × Destination is emitted once.
pub fn select_destinations(routes: List(Route), event: Event) -> List(String) {
  routes
  |> list.filter(fn(route) { matches_route(route, event) })
  |> list.flat_map(fn(route) { route.destinations })
  |> deduplicate
}

pub fn matching_routes(routes: List(Route), event: Event) -> List(Route) {
  list.filter(routes, fn(route) { matches_route(route, event) })
}

pub fn matches_route(route: Route, event: Event) -> Bool {
  route.source == event.source
  && event_type_matches(route.event, event.event_type)
  && list.all(route.filters, fn(filter) {
    filter.matches_value(filter, lookup_value(event, filter))
  })
}

/// フィルタパスの解決。`metadata.` プレフィックスで Event Metadata を、
/// それ以外は Event Data の dotted path を辿る。
/// Metadata は文字列で保持されるが、filter 値が数値の場合は数値として
/// 解決し直す。Eq と range 系で同一パスの一貫性を保つため。
fn lookup_value(event: Event, filter: Filter) -> Result(event.EventValue, Nil) {
  case string.starts_with(filter.path, "metadata.") {
    True -> {
      // Metadata のキーは受信時に小文字化されるため、照合側でも揃える。
      // ヘッダ名慣習(X-GitHub-Event)どおりに書いても一致する。
      let key =
        filter.path
        |> string.drop_start(string.length("metadata."))
        |> string.lowercase
      case dict.get(event.metadata, key) {
        Error(_) -> Error(Nil)
        Ok(text) -> Ok(coerce_metadata(text, filter.value))
      }
    }
    False -> event.get_path(event.data, filter.path)
  }
}

fn coerce_metadata(
  text: String,
  expected: event.EventValue,
) -> event.EventValue {
  case expected {
    event.Int(_) | event.Float(_) ->
      case int.parse(text) {
        Ok(n) -> event.Int(n)
        Error(_) ->
          case float.parse(text) {
            Ok(f) -> event.Float(f)
            Error(_) -> event.String(text)
          }
      }
    _ -> event.String(text)
  }
}

fn event_type_matches(pattern: String, event_type: String) -> Bool {
  pattern == "*" || pattern == event_type
}

fn deduplicate(names: List(String)) -> List(String) {
  let #(_seen, unique) =
    list.fold(names, #(set.new(), []), fn(acc, name) {
      let #(seen, out) = acc
      case set.contains(seen, name) {
        True -> acc
        False -> #(set.insert(seen, name), list.append(out, [name]))
      }
    })
  unique
}
