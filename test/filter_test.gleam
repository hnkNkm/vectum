import gleam/dict
import vectum/event
import vectum/filter.{Filter}

fn payment() -> event.EventValue {
  event.Object(
    dict.from_list([
      #("amount", event.Int(150_000)),
      #("currency", event.String("jpy")),
      #(
        "repository",
        event.Object(dict.from_list([#("name", event.String("backend"))])),
      ),
      #("tags", event.Array([event.String("vip"), event.String("eu")])),
    ]),
  )
}

pub fn eq_and_nested_path_test() {
  let f =
    Filter(
      path: "repository.name",
      op: filter.Eq,
      value: event.String("backend"),
    )
  assert filter.matches(f, payment())
}

pub fn neq_test() {
  let f = Filter(path: "currency", op: filter.Neq, value: event.String("usd"))
  assert filter.matches(f, payment())
}

pub fn gte_numeric_test() {
  let f = Filter(path: "amount", op: filter.Gte, value: event.Int(100_000))
  assert filter.matches(f, payment())
  let low = Filter(path: "amount", op: filter.Gte, value: event.Int(200_000))
  assert !filter.matches(low, payment())
}

pub fn contains_string_and_array_test() {
  let text =
    Filter(path: "currency", op: filter.Contains, value: event.String("jp"))
  assert filter.matches(text, payment())
  let item =
    Filter(path: "tags", op: filter.Contains, value: event.String("vip"))
  assert filter.matches(item, payment())
}

pub fn exists_and_not_exists_test() {
  let present = Filter(path: "amount", op: filter.Exists, value: event.Null)
  let missing = Filter(path: "nope", op: filter.NotExists, value: event.Null)
  let missing_fail =
    Filter(path: "amount", op: filter.NotExists, value: event.Null)
  assert filter.matches(present, payment())
  assert filter.matches(missing, payment())
  assert !filter.matches(missing_fail, payment())
}

pub fn and_combination_test() {
  let filters = [
    Filter(path: "amount", op: filter.Gte, value: event.Int(100_000)),
    Filter(path: "currency", op: filter.Eq, value: event.String("jpy")),
  ]
  assert filter.matches_all(filters, payment())
  let failing = [
    Filter(path: "amount", op: filter.Gte, value: event.Int(100_000)),
    Filter(path: "currency", op: filter.Eq, value: event.String("usd")),
  ]
  assert !filter.matches_all(failing, payment())
}

pub fn parse_op_rejects_unknown_test() {
  let assert Ok(filter.Eq) = filter.parse_op("EQ")
  let assert Error(_) = filter.parse_op("regex")
}

pub fn neq_missing_is_false_test() {
  let f = Filter(path: "nope", op: filter.Neq, value: event.String("x"))
  assert !filter.matches(f, payment())
}

pub fn int_comparison_is_exact_test() {
  // 2^62+1 は Float にすると 2^62 に丸められる。整数比較なら区別できる。
  let data =
    event.Object(
      dict.from_list([#("id", event.Int(4_611_686_018_427_387_905))]),
    )
  let f =
    Filter(
      path: "id",
      op: filter.Gt,
      value: event.Int(4_611_686_018_427_387_904),
    )
  assert filter.matches(f, data)
}

// ---- Grouped condition(#36) ----

fn resolve_in(
  data: event.EventValue,
) -> fn(filter.Filter) -> Result(event.EventValue, Nil) {
  fn(f: filter.Filter) { event.get_path(data, f.path) }
}

fn amount(value: Int) -> filter.Filter {
  filter.Filter(path: "amount", op: filter.Gte, value: event.Int(value))
}

/// `A OR B`(root any): leaf のどれかがマッチすれば真。
pub fn condition_any_or_test() {
  let condition =
    filter.Condition(op: filter.Any, children: [
      filter.Leaf(amount(200_000)),
      filter.Leaf(filter.Filter(
        path: "currency",
        op: filter.Eq,
        value: event.String("jpy"),
      )),
    ])
  let resolve = resolve_in(payment())
  assert filter.matches_condition(condition, resolve)

  let no_match =
    filter.Condition(op: filter.Any, children: [
      filter.Leaf(amount(200_000)),
      filter.Leaf(filter.Filter(
        path: "currency",
        op: filter.Eq,
        value: event.String("usd"),
      )),
    ])
  assert !filter.matches_condition(no_match, resolve)
}

/// `(A AND B) OR C`: root any の子に all group を持つ。
pub fn condition_all_group_inside_any_test() {
  // (amount >= 100_000 AND currency == "jpy") OR repository.name == "docs"
  let condition =
    filter.Condition(op: filter.Any, children: [
      filter.Group(
        filter.Condition(op: filter.All, children: [
          filter.Leaf(amount(100_000)),
          filter.Leaf(filter.Filter(
            path: "currency",
            op: filter.Eq,
            value: event.String("jpy"),
          )),
        ]),
      ),
      filter.Leaf(filter.Filter(
        path: "repository.name",
        op: filter.Eq,
        value: event.String("docs"),
      )),
    ])
  // group 側がマッチ(payment: amount 150_000 / jpy / backend)
  assert filter.matches_condition(condition, resolve_in(payment()))
  // C 側だけマッチ: 1 要素 object にデータを差し替え
  let docs =
    event.Object(
      dict.from_list([
        #(
          "repository",
          event.Object(dict.from_list([#("name", event.String("docs"))])),
        ),
      ]),
    )
  assert filter.matches_condition(condition, resolve_in(docs))
  // どちらも偽
  let other =
    event.Object(
      dict.from_list([
        #(
          "repository",
          event.Object(dict.from_list([#("name", event.String("other"))])),
        ),
      ]),
    )
  assert !filter.matches_condition(condition, resolve_in(other))
}

/// exists / not_exists は group 内でも leaf として使える。
pub fn condition_exists_and_not_exists_test() {
  let present =
    filter.Condition(op: filter.All, children: [
      filter.Leaf(filter.Filter(
        path: "amount",
        op: filter.Exists,
        value: event.Null,
      )),
      filter.Leaf(filter.Filter(
        path: "nope",
        op: filter.NotExists,
        value: event.Null,
      )),
    ])
  assert filter.matches_condition(present, resolve_in(payment()))

  let missing =
    filter.Condition(op: filter.All, children: [
      filter.Leaf(filter.Filter(
        path: "nope",
        op: filter.Exists,
        value: event.Null,
      )),
    ])
  assert !filter.matches_condition(missing, resolve_in(payment()))
  // all は 1 つでも偽なら偽
  let one_false =
    filter.Condition(op: filter.All, children: [
      filter.Leaf(amount(100_000)),
      filter.Leaf(filter.Filter(
        path: "amount",
        op: filter.NotExists,
        value: event.Null,
      )),
    ])
  assert !filter.matches_condition(one_false, resolve_in(payment()))
}

pub fn parse_group_op_test() {
  let assert Ok(filter.All) = filter.parse_group_op("all")
  let assert Ok(filter.Any) = filter.parse_group_op("ANY")
  let assert Error(_) = filter.parse_group_op("xor")
}

pub fn group_op_to_string_test() {
  assert filter.group_op_to_string(filter.All) == "all"
  assert filter.group_op_to_string(filter.Any) == "any"
}
