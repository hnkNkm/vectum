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

/// Grouped condition の結合演算子(#36)。
pub type GroupOp {
  All
  Any
}

/// `[routes.condition]` のルート condition。`op` で子を AND / OR 結合する。
pub type Condition {
  Condition(op: GroupOp, children: List(ConditionNode))
}

/// Condition の子。leaf は従来の Filter、group は再帰的な Condition。
pub type ConditionNode {
  Group(child: Condition)
  Leaf(filter: Filter)
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

pub fn parse_group_op(name: String) -> Result(GroupOp, String) {
  case string.lowercase(name) {
    "all" -> Ok(All)
    "any" -> Ok(Any)
    other -> Error("invalid condition operator: " <> other)
  }
}

pub fn group_op_to_string(op: GroupOp) -> String {
  case op {
    All -> "all"
    Any -> "any"
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
      // 欠損パスは非マッチに倒す。存在しない field への neq は
      // NotExists で表現する。Eq/Contains との対称性のため。
      case found {
        Ok(value) -> !event.equal(value, filter.value)
        Error(_) -> False
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

/// Grouped condition の評価(#36)。
/// `resolve` は leaf の path を解決済みの値へ変換する(Data / Metadata の
/// 解決方法は呼び出し側で分岐する)。子は設定順(ドキュメント順)に評価し、
/// `all` は最初の偽、`any` は最初の真で短絡する。
pub fn matches_condition(
  condition: Condition,
  resolve: fn(Filter) -> Result(EventValue, Nil),
) -> Bool {
  case condition.op {
    All -> matches_all_children(condition.children, resolve)
    Any -> matches_any_children(condition.children, resolve)
  }
}

fn matches_all_children(
  children: List(ConditionNode),
  resolve: fn(Filter) -> Result(EventValue, Nil),
) -> Bool {
  case children {
    [] -> True
    [child, ..rest] ->
      case matches_node(child, resolve) {
        True -> matches_all_children(rest, resolve)
        False -> False
      }
  }
}

fn matches_any_children(
  children: List(ConditionNode),
  resolve: fn(Filter) -> Result(EventValue, Nil),
) -> Bool {
  case children {
    [] -> False
    [child, ..rest] ->
      case matches_node(child, resolve) {
        True -> True
        False -> matches_any_children(rest, resolve)
      }
  }
}

fn matches_node(
  node: ConditionNode,
  resolve: fn(Filter) -> Result(EventValue, Nil),
) -> Bool {
  case node {
    Leaf(filter) -> matches_value(filter, resolve(filter))
    Group(child) -> matches_condition(child, resolve)
  }
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn compare_numbers(op: Op, left: EventValue, right: EventValue) -> Bool {
  // Int 同士は整数のまま比較する。Float 経由では 2^53 超で誤順序になる。
  case left, right {
    event.Int(a), event.Int(b) ->
      case op {
        Gt -> a > b
        Gte -> a >= b
        Lt -> a < b
        Lte -> a <= b
        _ -> False
      }
    _, _ ->
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
