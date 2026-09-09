import gleam/dict
import gleam/option.{None, Some}
import vectum/event
import vectum/filter.{Filter}
import vectum/route.{Route}

fn ev(source: String, typ: String, name: String) -> event.Event {
  event.Event(
    id: "e1",
    source:,
    event_type: typ,
    timestamp: "t",
    data: event.Object(
      dict.from_list([
        #(
          "repository",
          event.Object(dict.from_list([#("name", event.String(name))])),
        ),
      ]),
    ),
    metadata: dict.new(),
  )
}

pub fn fan_out_and_dedup_test() {
  let routes = [
    Route(
      name: "a",
      source: "github",
      event: "push",
      destinations: ["ci", "audit"],
      filters: [],
      condition: None,
    ),
    Route(
      name: "b",
      source: "github",
      event: "push",
      destinations: ["audit", "notify"],
      filters: [],
      condition: None,
    ),
    Route(
      name: "c",
      source: "stripe",
      event: "push",
      destinations: ["fraud"],
      filters: [],
      condition: None,
    ),
  ]
  let dests = route.select_destinations(routes, ev("github", "push", "any"))
  assert dests == ["ci", "audit", "notify"]
}

pub fn wildcard_event_and_filter_test() {
  let routes = [
    Route(
      name: "backend-pr",
      source: "github",
      event: "pull_request",
      destinations: ["audit"],
      filters: [
        Filter(
          path: "repository.name",
          op: filter.Eq,
          value: event.String("backend"),
        ),
      ],
      condition: None,
    ),
    Route(
      name: "all-internal",
      source: "internal",
      event: "*",
      destinations: ["audit"],
      filters: [],
      condition: None,
    ),
  ]
  assert route.select_destinations(
      routes,
      ev("github", "pull_request", "backend"),
    )
    == ["audit"]
  assert route.select_destinations(routes, ev("github", "pull_request", "docs"))
    == []
  assert route.select_destinations(routes, ev("internal", "anything", "x"))
    == ["audit"]
}

// ---- Metadata フィルタ ----

fn meta_ev(metadata: List(#(String, String))) -> event.Event {
  event.Event(
    id: "m1",
    source: "github",
    event_type: "push",
    timestamp: "t",
    data: event.Object(dict.from_list([#("n", event.Int(1))])),
    metadata: dict.from_list(metadata),
  )
}

fn meta_route(op: filter.Op, value: event.EventValue) -> route.Route {
  Route(
    name: "m",
    source: "github",
    event: "*",
    destinations: ["out"],
    filters: [Filter(path: "metadata.x-github-event", op:, value:)],
    condition: None,
  )
}

pub fn metadata_filter_eq_matches_header_test() {
  let e = meta_ev([#("x-github-event", "push"), #("authorization", "secret")])
  assert route.matches_route(meta_route(filter.Eq, event.String("push")), e)
  assert !route.matches_route(
    meta_route(filter.Eq, event.String("pull_request")),
    e,
  )
}

pub fn metadata_filter_exists_and_neq_test() {
  let with_header = meta_ev([#("x-github-event", "push")])
  let without = meta_ev([])

  // exists / not_exists
  assert route.matches_route(meta_route(filter.Exists, event.Null), with_header)
  assert !route.matches_route(meta_route(filter.Exists, event.Null), without)

  // 欠損パスへの neq は偽。存在しない field は NotExists で表現する。
  assert !route.matches_route(
    meta_route(filter.Neq, event.String("push")),
    without,
  )
  assert route.matches_route(
    meta_route(filter.Neq, event.String("pull_request")),
    with_header,
  )
}

pub fn metadata_numeric_eq_matches_test() {
  let e = meta_ev([#("x-retry", "3")])
  let r =
    Route(
      name: "m",
      source: "github",
      event: "*",
      destinations: ["out"],
      filters: [
        Filter(path: "metadata.x-retry", op: filter.Eq, value: event.Int(3)),
      ],
      condition: None,
    )
  assert route.matches_route(r, e)
}

pub fn metadata_filter_does_not_leak_into_data_test() {
  // Data 側に同名キーがあっても、metadata. プレフィックスは Metadata を見る
  let e =
    event.Event(
      id: "d1",
      source: "github",
      event_type: "push",
      timestamp: "t",
      data: event.Object(
        dict.from_list([
          #("x-github-event", event.String("decoy")),
        ]),
      ),
      metadata: dict.from_list([#("x-github-event", "push")]),
    )
  assert route.matches_route(meta_route(filter.Eq, event.String("push")), e)
}

pub fn metadata_filter_key_is_case_insensitive_test() {
  let e = meta_ev([#("x-github-event", "push")])

  // ヘッダ名慣習の大小文字でも同じキーにマッチする(#27)
  let upper =
    Route(
      name: "u",
      source: "github",
      event: "*",
      destinations: ["out"],
      filters: [
        Filter(
          path: "metadata.X-GitHub-Event",
          op: filter.Eq,
          value: event.String("push"),
        ),
      ],
      condition: None,
    )
  assert route.matches_route(upper, e)
  assert route.matches_route(meta_route(filter.Eq, event.String("push")), e)
}

// ---- Grouped condition(#36) ----

fn cond_ev(
  name: String,
  n: Int,
  metadata: List(#(String, String)),
) -> event.Event {
  event.Event(
    id: "c1",
    source: "github",
    event_type: "push",
    timestamp: "t",
    data: event.Object(
      dict.from_list([
        #("n", event.Int(n)),
        #(
          "repository",
          event.Object(dict.from_list([#("name", event.String(name))])),
        ),
      ]),
    ),
    metadata: dict.from_list(metadata),
  )
}

fn cond_route(condition: filter.Condition) -> route.Route {
  Route(
    name: "c",
    source: "github",
    event: "*",
    destinations: ["out"],
    filters: [],
    condition: Some(condition),
  )
}

/// `A OR B`: どちらかの leaf がマッチすれば route にマッチする。
pub fn condition_any_matches_either_leaf_test() {
  let condition =
    filter.Condition(op: filter.Any, children: [
      filter.Leaf(filter.Filter(path: "n", op: filter.Gte, value: event.Int(5))),
      filter.Leaf(filter.Filter(
        path: "metadata.x-github-event",
        op: filter.Eq,
        value: event.String("alert"),
      )),
    ])
  let r = cond_route(condition)
  // A だけマッチ
  assert route.matches_route(r, cond_ev("docs", 10, []))
  // B だけマッチ(metadata leaf)
  assert route.matches_route(
    r,
    cond_ev("docs", 1, [#("x-github-event", "alert")]),
  )
  // どちらもマッチしない
  assert !route.matches_route(r, cond_ev("docs", 1, []))
}

/// `(A AND B) OR C`: dotted path と metadata. を nested group に含めて評価する。
pub fn condition_all_inside_any_test() {
  let condition =
    filter.Condition(op: filter.Any, children: [
      filter.Group(
        filter.Condition(op: filter.All, children: [
          filter.Leaf(filter.Filter(
            path: "repository.name",
            op: filter.Eq,
            value: event.String("backend"),
          )),
          filter.Leaf(filter.Filter(
            path: "metadata.x-github-event",
            op: filter.Eq,
            value: event.String("push"),
          )),
        ]),
      ),
      filter.Leaf(filter.Filter(
        path: "n",
        op: filter.Gte,
        value: event.Int(100),
      )),
    ])
  let r = cond_route(condition)
  // (A AND B): dotted + metadata が両方マッチ
  assert route.matches_route(
    r,
    cond_ev("backend", 1, [#("x-github-event", "push")]),
  )
  // C だけマッチ(group は偽)
  assert route.matches_route(r, cond_ev("docs", 200, []))
  // どれもマッチしない
  assert !route.matches_route(
    r,
    cond_ev("docs", 1, [#("x-github-event", "push")]),
  )
  // A AND B の片方だけではマッチしない
  assert !route.matches_route(r, cond_ev("backend", 1, []))
}

/// exists / not_exists を group の中で使える(Data と Metadata 両方)。
pub fn condition_exists_inside_group_test() {
  let condition =
    filter.Condition(op: filter.All, children: [
      filter.Leaf(filter.Filter(
        path: "repository.name",
        op: filter.Exists,
        value: event.Null,
      )),
      filter.Leaf(filter.Filter(
        path: "metadata.x-github-event",
        op: filter.Exists,
        value: event.Null,
      )),
      filter.Leaf(filter.Filter(
        path: "metadata.x-nope",
        op: filter.NotExists,
        value: event.Null,
      )),
    ])
  let r = cond_route(condition)
  assert route.matches_route(
    r,
    cond_ev("backend", 1, [#("x-github-event", "push")]),
  )
  // metadata leaf が偽
  assert !route.matches_route(r, cond_ev("backend", 1, []))
  // metadata の not_exists leaf が偽
  assert !route.matches_route(
    r,
    cond_ev("backend", 1, [#("x-github-event", "push"), #("x-nope", "x")]),
  )
}
