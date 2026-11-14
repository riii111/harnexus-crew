///|
/// A review `harnexus-task review` finished in a Cloud session, as its output names it.
pub(all) struct CloudReview {
  /// Names the review by its reviewer, head, answer and, for a reply to a question, when it was asked, so a review read twice is taken once.
  key : String
  reviewer : String
  verdict : String?
  task_id : String?
  head : String?
  answer : String
}

///|
/// The reviews whose output a Cloud session read at or after `from` and before `to`, in order, each once; the output may be read from a file it was written to.
pub fn reviews_in(
  records : Array[Json],
  from~ : Int32 = 0,
  to? : Int32,
) -> Array[CloudReview] {
  let end = to.unwrap_or(records.length())
  let reviews : Map[String, CloudReview] = Map([])

  for index, record in records {
    if index < from || index >= end {
      continue
    }

    for block in content_of(record) {
      guard block.get("type") is Some(String("tool_result")) else { continue }

      if block.get("is_error") is Some(True) {
        continue
      }

      for text in texts_of(block.get("content")) {
        if review_of(text) is Some(review) && !reviews.contains(review.key) {
          reviews[review.key] = review
        }
      }
    }
  }

  reviews.values().collect()
}

///|
pub fn review_text(review : CloudReview) -> String {
  let head = match review.head {
    Some(head) if head.length() > 7 => " on `\{head[:7]}`"
    Some(head) => " on `\{head}`"
    None => ""
  }

  "\{@text.js_trim(review.answer)}\n\n_Codex reviewer `\{review.reviewer}`\{head}, run in a Cloud session. Ask for changes in the worker's chat._"
}

///|
/// What the session that ran the reviewer is asked when the user writes in the reviewer's chat; the answer comes back as a review does.
pub fn reviewer_ask(reviewer : String, text : String) -> String {
  "The user sent this to your Codex reviewer `\{reviewer}` from its Review chat in the Codex App:\n\n\{text}\n\nPass it to the same reviewer: write it to a file and run `harnexus-crew review --request <your review request file> --ask <that file>`, then reply with the reviewer's answer as it is."
}

///|
pub fn uuid_of(record : Json?) -> String? {
  guard record is Some(Object(members)) else { return None }

  match members.get("uuid") {
    Some(String(uuid)) => Some(uuid)
    _ => None
  }
}

///|
/// The mark that tells a chat showing a Cloud session from other chats in the app's list.
pub const CLOUD_MARK : String = "\u{2601}\u{FE0F}"

///|
pub const REVIEW_ASK_SENT : String = "Sent to the worker running this reviewer, which passes it on; the reviewer's answer appears here once the worker's session is copied."

///|
pub const REVIEW_ASK_UNROUTED : String = "The Cloud session that ran this reviewer is not shown in a chat here, so its answer could not come back and the message was not sent. Link the worker's session with /cloud, or ask in the worker's chat."

///|
pub const REVIEW_ASK_UNKNOWN : String = "The message may or may not have reached the worker's session, so it is not sent again; check the worker's chat."

///|
fn content_of(record : Json) -> Array[Map[String, Json]] {
  guard record is Object(members) else { return [] }
  guard members.get("message") is Some(Object(message)) else { return [] }
  guard message.get("content") is Some(Array(content)) else { return [] }

  let blocks = []

  for item in content {
    if item is Object(block) {
      blocks.push(block)
    }
  }

  blocks
}

///|
fn texts_of(content : Json?) -> Array[String] {
  match content {
    Some(String(text)) => [text]
    Some(Array(items)) => {
      let texts = []

      for item in items {
        if item is Object(members) && members.get("text") is Some(String(text)) {
          texts.push(text)
        }
      }

      texts
    }
    _ => []
  }
}

///|
/// The output is `harnexus-task`'s JSON, alone or with other lines around it, and with line numbers when a file was read.
fn review_of(text : String) -> CloudReview? {
  guard text.contains("\"reviewer\"") else { return None }

  let plain = strip_line_numbers(text)
  guard plain.find("{") is Some(start) &&
    plain.rev_find("}") is Some(end) &&
    end > start else {
    return None
  }

  let parsed = @jsonio.parse(plain[start:end + 1].to_owned()) catch {
    _ => return None
  }
  guard parsed is Object(output) else { return None }
  guard output.get("status") is Some(String("completed")) &&
    output.get("reviewer") is Some(String(reviewer)) &&
    output.get("answer") is Some(String(answer)) &&
    @text.js_trim(answer) != "" else {
    return None
  }

  let head = text_or_none(output.get("head"))
  let asked_at = text_or_none(output.get("askedAt"))
  let identity = "\{reviewer}\u{0}\{head.unwrap_or("")}\u{0}\{asked_at.unwrap_or("")}\u{0}\{answer}"

  Some({
    key: @store.sha256_hex(identity)[:32].to_owned(),
    reviewer,
    verdict: text_or_none(output.get("verdict")),
    task_id: text_or_none(output.get("taskId")),
    head,
    answer,
  })
}

///|
fn strip_line_numbers(text : String) -> String {
  let units = text.code_units()
  let out = StringBuilder()
  let mut copied_from = 0
  let mut at = 0
  let mut line_start = true

  while at < units.length() {
    if line_start {
      let width = line_number_width(units, at)
      if width > 0 {
        out.write_string(text[copied_from:at].to_owned())
        at += width
        copied_from = at
        line_start = false
        continue
      }
    }

    // The line terminators of JS's multiline `^`.
    let unit = units[at]
    line_start = unit == '\n' ||
      unit == '\r' ||
      unit == '\u{2028}' ||
      unit == '\u{2029}'
    at += 1
  }

  out.write_string(text[copied_from:].to_owned())

  out.to_string()
}

///|
fn line_number_width(units : ArrayView[UInt16], at : Int32) -> Int32 {
  let mut end = at
  while end < units.length() && units[end] == ' ' {
    end += 1
  }

  let digits_from = end

  while end < units.length() && units[end] >= '0' && units[end] <= '9' {
    end += 1
  }

  if end == digits_from || end >= units.length() || units[end] != '\t' {
    0
  } else {
    end + 1 - at
  }
}

///|
fn text_or_none(value : Json?) -> String? {
  match value {
    Some(String(text)) if text != "" => Some(text)
    _ => None
  }
}
