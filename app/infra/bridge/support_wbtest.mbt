///|
fn json_text(value : Json) -> String {
  value.stringify()
}

///|
fn parse(text : String) -> Json {
  @jsonio.parse(text) catch {
    _ => abort("not JSON: \{text}")
  }
}

///|
fn failed_json(outcome : String, error : String) -> String {
  json_text(
    Json::object({
      "outcome": Json::string(outcome),
      "error": Json::string(error),
    }),
  )
}
