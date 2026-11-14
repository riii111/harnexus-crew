///|
fn object(pairs : Array[(String, Json)]) -> Json {
  let members : Map[String, Json] = Map([])
  for pair in pairs {
    let (name, value) = pair
    members[name] = value
  }
  Json::object(members)
}

///|
fn field(value : Json, name : String) -> Json? {
  match value {
    Object(members) => members.get(name)
    _ => None
  }
}

///|
fn text_member(value : Json, name : String) -> String? {
  match field(value, name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn text_member_or_empty(value : Json, name : String) -> String {
  text_member(value, name).unwrap_or("")
}

///|
fn is_object(value : Json) -> Bool {
  value is Object(_)
}

///|
fn objects_in(value : Json?) -> Array[Json] {
  match value {
    Some(Array(items)) => items.filter(is_object)
    _ => []
  }
}

///|
fn strings_in(value : Json?) -> Array[String] {
  let texts = []
  if value is Some(Array(items)) {
    for item in items {
      if item is String(text) {
        texts.push(text)
      }
    }
  }
  texts
}

///|
fn text_or_null(text : String?) -> Json {
  match text {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
fn text_or_none(value : Json?) -> String? {
  match value {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn short_hash(text : String) -> String {
  @store.sha256_hex(text)[:16].to_owned()
}

///|
fn[T] lift_file_failure(
  work : () -> T raise @store.FileFailed,
) -> T raise @failure.TaskFailed {
  work() catch {
    failed => @failure.fail(failed.user_message())
  }
}
