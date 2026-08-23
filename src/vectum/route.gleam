import gleam/dict
import gleam/list
import gleam/result
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
    filter.matches_value(filter, lookup_value(event, filter.path))
  })
}

/// フィルタパスの解決。`metadata.` プレフィックスで Event Metadata を、
/// それ以外は Event Data の dotted path を辿る。
fn lookup_value(event: Event, path: String) -> Result(event.EventValue, Nil) {
  case string.starts_with(path, "metadata.") {
    True -> {
      let key = string.drop_start(path, string.length("metadata."))
      dict.get(event.metadata, key)
      |> result.map(event.String)
    }
    False -> event.get_path(event.data, path)
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
