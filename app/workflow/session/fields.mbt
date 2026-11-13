///|
/// The values Python and JS count as false, which decide whether state recorded by either version counts as present.
fn truthy(value : Json) -> Bool {
  match value {
    Null | False => false
    True => true
    Number(number, ..) => number != 0.0
    String(text) => text.length() > 0
    Array(items) => !items.is_empty()
    Object(members) => !members.is_empty()
  }
}

///|
fn value_of(members : Map[String, Json], key : String) -> Json {
  members.get(key).unwrap_or(Json::null())
}

///|
/// Structural equality as the TypeScript build's strict deep comparison has it: members in any order, numbers by value.
fn json_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) | (True, True) | (False, False) => true
    (Number(x, ..), Number(y, ..)) => x == y
    (String(x), String(y)) => x == y
    (Array(x), Array(y)) =>
      x.length() == y.length() &&
      (for i in 0..<x.length() {
        if !json_equal(x[i], y[i]) {
          break false
        }
      } nobreak {
        true
      })
    (Object(x), Object(y)) =>
      x.length() == y.length() &&
      (for key, item in x {
        match y.get(key) {
          Some(other) if json_equal(item, other) => ()
          _ => break false
        }
      } nobreak {
        true
      })
    _ => false
  }
}

///|
fn settings_of(record : Json) -> Json {
  Json::object({
    "model": @jsonio.field(record, "model"),
    "effort": @jsonio.field(record, "effort"),
  })
}

///|
fn sent_settings(sent : Json) -> Json {
  let requested = settings_of(@jsonio.field(sent, "expected"))
  let asked = !(@jsonio.field(requested, "model") is Null) ||
    !(@jsonio.field(requested, "effort") is Null)
  if @jsonio.field(sent, "tool") is String("create_thread") || asked {
    Json::object({
      "requested": requested,
      "actual": settings_of(@jsonio.field(sent, "actual")),
    })
  } else {
    // A send without settings cannot confirm the actual settings, so report null instead of guessing.
    Json::null()
  }
}

///|
fn thread_title(kind : String, request : Json) -> String {
  let name = @jsonio.field(request, "displayName")
  if truthy(name) {
    "\{kind}｜\{@jsonio.as_text(name)}"
  } else {
    "\{kind} \{@jsonio.as_text(@jsonio.field(request, "taskId"))}"
  }
}
