import gleam/dict
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
    ),
    Route(
      name: "b",
      source: "github",
      event: "push",
      destinations: ["audit", "notify"],
      filters: [],
    ),
    Route(
      name: "c",
      source: "stripe",
      event: "push",
      destinations: ["fraud"],
      filters: [],
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
    ),
    Route(
      name: "all-internal",
      source: "internal",
      event: "*",
      destinations: ["audit"],
      filters: [],
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

pub fn metadata_filter_exists_and_neq_missing_test() {
  let with_header = meta_ev([#("x-github-event", "push")])
  let without = meta_ev([])

  // exists / not_exists
  assert route.matches_route(meta_route(filter.Exists, event.Null), with_header)
  assert !route.matches_route(meta_route(filter.Exists, event.Null), without)

  // 対象が無い場合の neq は真(Data の neq と同じ意味論)
  assert route.matches_route(
    meta_route(filter.Neq, event.String("push")),
    without,
  )
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
