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
