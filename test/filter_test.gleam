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
