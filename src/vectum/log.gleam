import gleam/io
import gleam/json
import gleam/list

pub fn info(fields: List(#(String, String))) -> Nil {
  write("info", fields)
}

pub fn error(fields: List(#(String, String))) -> Nil {
  write("error", fields)
}

fn write(level: String, fields: List(#(String, String))) -> Nil {
  let pairs = [#("level", json.string(level)), ..to_json(fields)]
  io.println(json.to_string(json.object(pairs)))
}

fn to_json(fields: List(#(String, String))) -> List(#(String, json.Json)) {
  list.map(fields, fn(pair) { #(pair.0, json.string(pair.1)) })
}
