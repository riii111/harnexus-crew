///|
/// The model and thinking a turn was asked for or ran with; None is a setting nobody named or the app left out.
pub(all) struct TurnSettings {
  model : String?
  effort : String?
}

///|
/// Says how the settings a turn ran with differ from those asked for, as the bridge words a refused first turn.
pub fn refusal_of(expected : TurnSettings, actual : TurnSettings) -> String {
  let differences = []
  for
    found in [
      difference("model", expected.model, actual.model),
      difference("effort", expected.effort, actual.effort),
    ] {
    if found is Some(text) {
      differences.push(text)
    }
  }

  differences.join(" and ")
}

///|
fn difference(key : String, expected : String?, actual : String?) -> String? {
  // A value the app leaves out cannot confirm what was asked, so it refuses the turn like a different one; a setting nobody asked for is not checked.
  guard expected is Some(wanted) && expected != actual else { return None }

  match actual {
    Some(ran) => Some("asked for \{key} \{ran} instead of \{wanted}")
    None => Some("did not say which \{key} (expected \{wanted})")
  }
}
