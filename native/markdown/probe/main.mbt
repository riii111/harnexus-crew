///|
/// A test driver: `test/native/markdown.test.ts` runs it with the path of a template and reads which candidate link targets Markdown judges to be links.
/// It is not part of the CLI.
fn main {
  let path = @env.args().get(1).unwrap_or("")
  let reply = try {
    let template = @store.read_regular_text(path)
    let nonce = @store.new_uuid().replace_all(old="-", new="")
    let selected = @markdown.links(template, nonce~).map(fn(candidate) {
      Json::object({
        "index": Json::number(candidate.index.to_double()),
        "raw": Json::string(candidate.raw),
      })
    })
    Json::object({ "selected": Json::array(selected) })
  } catch {
    @failure.TaskFailed(message) =>
      Json::object({ "error": Json::string(message) })
    failed => Json::object({ "error": Json::string(failed.to_string()) })
  }
  @sys.write_text(1, @jsonio.stringify(reply) + "\n") catch {
    _ => abort("cannot write")
  }
}
