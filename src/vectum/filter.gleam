import gleam/float
import gleam/int
import gleam/list
import gleam/string
import vectum/event.{type EventValue}

pub type Op {
  Eq
  Neq
  Gt
  Gte
  Lt
  Lte
  Contains
  Exists
  NotExists
}

pub type Filter {
  Filter(path: String, op: Op, value: EventValue)
}

pub fn parse_op(name: String) -> Result(Op, String) {
  case string.lowercase(name) {
    "eq" -> Ok(Eq)
    "neq" -> Ok(Neq)
    "gt" -> Ok(Gt)
    "gte" -> Ok(Gte)
    "lt" -> Ok(Lt)
    "lte" -> Ok(Lte)
    "contains" -> Ok(Contains)
    "exists" -> Ok(Exists)
    "not_exists" -> Ok(NotExists)
    other -> Error("invalid filter operator: " <> other)
  }
}

pub fn op_to_string(op: Op) -> String {
  case op {
    Eq -> "eq"
    Neq -> "neq"
    Gt -> "gt"
    Gte -> "gte"
    Lt -> "lt"
    Lte -> "lte"
    Contains -> "contains"
    Exists -> "exists"
    NotExists -> "not_exists"
  }
}

pub fn matches(filter: Filter, data: EventValue) -> Bool {
  matches_value(filter, event.get_path(data, filter.path))
}

/// 解決済みのパス値に対してフィルタを評価する。
/// Metadata フィルタなど、Data 以外のソースを対象にするために分離している。
pub fn matches_value(filter: Filter, found: Result(EventValue, Nil)) -> Bool {
  case filter.op {
    Exists -> result_is_ok(found)
    NotExists -> !result_is_ok(found)
    Eq ->
      case found {
        Ok(value) -> event.equal(value, filter.value)
        Error(_) -> False
      }
    Neq ->
      case found {
        Ok(value) -> !event.equal(value, filter.value)
        Error(_) -> True
      }
    Gt | Gte | Lt | Lte ->
      case found {
        Ok(value) -> compare_numbers(filter.op, value, filter.value)
        Error(_) -> False
      }
    Contains ->
      case found {
        Ok(value) -> contains(value, filter.value)
        Error(_) -> False
      }
  }
}

/// v0.1: filters on the same rule are AND.
pub fn matches_all(filters: List(Filter), data: EventValue) -> Bool {
  list.all(filters, fn(filter) { matches(filter, data) })
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn compare_numbers(op: Op, left: EventValue, right: EventValue) -> Bool {
  case as_number(left), as_number(right) {
    Ok(a), Ok(b) ->
      case op {
        Gt -> a >. b
        Gte -> a >=. b
        Lt -> a <. b
        Lte -> a <=. b
        _ -> False
      }
    _, _ -> False
  }
}

fn as_number(value: EventValue) -> Result(Float, Nil) {
  case value {
    event.Int(n) -> Ok(int.to_float(n))
    event.Float(n) -> Ok(n)
    event.String(text) ->
      case int.parse(text) {
        Ok(n) -> Ok(int.to_float(n))
        Error(_) -> float.parse(text)
      }
    _ -> Error(Nil)
  }
}

fn contains(haystack: EventValue, needle: EventValue) -> Bool {
  case haystack, needle {
    event.String(text), event.String(part) -> string.contains(text, part)
    event.Array(items), _ ->
      list.any(items, fn(item) { event.equal(item, needle) })
    _, _ -> False
  }
}
