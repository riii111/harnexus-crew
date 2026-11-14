///|
/// A candidate link target in a template: the text between `](` and `)`, its place among the template's candidates, and where it sits as UTF-16 offsets.
pub struct Candidate {
  index : Int32
  raw : String
  start : Int32
  end : Int32
}

///|
const CLOSE_BRACKET : UInt16 = 0x5D

///|
const OPEN_PAREN : UInt16 = 0x28

///|
const CLOSE_PAREN : UInt16 = 0x29

///|
const NEWLINE : UInt16 = 0x0A

///|
const BACKTICK : UInt16 = 0x60

///|
const STATUS_OK : Int32 = 0

///|
const STATUS_PARSE_FAILED : Int32 = 1

///|
/// The candidates that Markdown reads as the destination of a link or an image, in template order.
/// `nonce` makes the stand-in marker for each candidate; it must not occur in the template.
pub fn links(
  template : String,
  nonce~ : String,
) -> Array[Candidate] raise @failure.TaskFailed {
  let candidates = candidates_of(template)
  // Each whole target is swapped for a bare marker, so a target with spaces or brackets still counts as a link.
  let marked = replace_with_markers(template, candidates, nonce)
  // A comment spanning blocks would be split by the parser, so its text is blanked first, keeping the lines.
  let seen = find_destinations(blank_comments(marked))
  let found = []
  for candidate in candidates {
    if seen.contains(marker_of(nonce, candidate.index)) {
      found.push(candidate)
    }
  }
  found
}

///|
/// An inline link target, up to the first closing parenthesis on its line.
/// A line opening with `[label]:` may be prose, so reference definitions are left as written.
fn candidates_of(template : String) -> Array[Candidate] {
  let units = template.code_units()
  let found = []
  let mut at = 0
  while at + 1 < units.length() {
    if units[at] == CLOSE_BRACKET && units[at + 1] == OPEN_PAREN {
      let start = at + 2
      let mut end = start
      // A `](` in code must not take in the link after it, so the target never crosses a backtick.
      while end < units.length() &&
            units[end] != CLOSE_PAREN &&
            units[end] != NEWLINE &&
            units[end] != BACKTICK {
        end += 1
      }
      if end < units.length() && units[end] == CLOSE_PAREN {
        found.push({
          index: found.length(),
          raw: template[start:end].to_owned(),
          start,
          end,
        })
        at = end + 1
        continue
      }
    }
    at += 1
  }
  found
}

///|
fn replace_with_markers(
  template : String,
  candidates : Array[Candidate],
  nonce : String,
) -> String {
  let out = StringBuilder()
  let mut last = 0
  for candidate in candidates {
    out.write_view(template[last:candidate.start])
    out.write_string(marker_of(nonce, candidate.index))
    last = candidate.end
  }
  out.write_view(template[last:])
  out.to_string()
}

///|
fn find_destinations(
  text : String,
) -> @hashset.HashSet[String] raise @failure.TaskFailed {
  let bytes = @utf8.encode(text)
  read_destinations(destinations_raw(bytes, bytes.length()))
}

///|
fn read_destinations(
  reply : Bytes,
) -> @hashset.HashSet[String] raise @failure.TaskFailed {
  let status = reply[0].to_int()
  // To prevent a parser failure from bypassing link validation, fail instead of reporting no links.
  if status == STATUS_PARSE_FAILED {
    @failure.fail("the Markdown parser (md4c) failed")
  }
  if status != STATUS_OK {
    @failure.fail("the Markdown parser (md4c) ran out of memory")
  }
  let found = @hashset.HashSet([])
  let mut at = 1
  while at < reply.length() {
    let size = decode_length(reply, at + 1)
    let start = at + 5
    if start + size > reply.length() {
      @failure.fail("the Markdown parser (md4c) returned a truncated record")
    }
    found.add(@utf8.decode_lossy(reply[start:start + size]))
    at = start + size
  }
  found
}

///|
fn blank_comments(text : String) -> String {
  let units = text.code_units()
  let out = StringBuilder()
  let mut copied = 0
  let mut at = 0
  while at + 3 < units.length() {
    if is_comment_open(units, at) {
      let close = find_comment_close(units, at + 4)
      if close < 0 {
        break
      }
      out.write_view(text[copied:at])
      for index in at..<(close + 3) {
        out.write_char(if units[index] == NEWLINE { '\n' } else { ' ' })
      }
      copied = close + 3
      at = copied
    } else {
      at += 1
    }
  }
  out.write_view(text[copied:])
  out.to_string()
}

///|
fn marker_of(nonce : String, index : Int32) -> String {
  "hx\{nonce}n\{index}x"
}

///|
fn is_comment_open(units : ArrayView[UInt16], at : Int32) -> Bool {
  units[at] == '<' &&
  units[at + 1] == '!' &&
  units[at + 2] == '-' &&
  units[at + 3] == '-'
}

///|
fn find_comment_close(units : ArrayView[UInt16], from : Int32) -> Int32 {
  let mut at = from
  while at + 2 < units.length() {
    if units[at] == '-' && units[at + 1] == '-' && units[at + 2] == '>' {
      return at
    }
    at += 1
  }
  -1
}

///|
fn decode_length(reply : Bytes, at : Int32) -> Int32 {
  reply[at].to_int() |
  (reply[at + 1].to_int() << 8) |
  (reply[at + 2].to_int() << 16) |
  (reply[at + 3].to_int() << 24)
}

///|
#borrow(text)
extern "C" fn destinations_raw(text : Bytes, size : Int32) -> Bytes = "harnexus_md_destinations"
