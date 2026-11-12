///|
fn json(text : String) -> Json {
  @jsonio.parse(text) catch {
    _ => abort("not JSON: \{text}")
  }
}

///|
test "save_json writes one space of indent and load reads it back" {
  in_scratch(directory => {
    let path = "\{directory}/session/state.json"
    save_json(path, json("{\"a\":[1,{\"b\":null}],\"c\":{}}"), exclusive=false)
    assert_eq(
      read_text(path),
      "{\n \"a\": [\n  1,\n  {\n   \"b\": null\n  }\n ],\n \"c\": {}\n}",
    )
    assert_eq(
      @jsonio.stringify(load(path)),
      "{\"a\":[1,{\"b\":null}],\"c\":{}}",
    )
    assert_eq(names_in("\{directory}/session"), ["state.json"])
  })
}

///|
test "save_json replaces an existing record unless it is exclusive" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"
    save_json(path, json("{\"v\":1}"), exclusive=false)
    save_json(path, json("{\"v\":2}"), exclusive=false)
    assert_eq(@jsonio.stringify(load(path)), "{\"v\":2}")
    assert_eq(
      task_failure(() => save_json(path, json("{\"v\":3}"), exclusive=true)),
      "another harnexus-crew run is sending; inspect \{path}",
    )
    assert_eq(@jsonio.stringify(load(path)), "{\"v\":2}")
  })
}

///|
test "save_json creates a record exclusively once" {
  in_scratch(directory => {
    let path = "\{directory}/pending.json"
    save_json(path, json("{\"sent\":false}"), exclusive=true)
    assert_eq(@jsonio.stringify(load(path)), "{\"sent\":false}")
  })
}

///|
test "save_json keeps unknown members and an unpaired surrogate escape" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"
    let data = json("{\"known\":1,\"extra\":{\"x\":[\"\\ud800\"]}}")
    save_json(path, data, exclusive=false)
    assert_eq(read_text(path).contains("\\ud800"), true)
    assert_eq(@jsonio.stringify(load(path)), @jsonio.stringify(data))
  })
}

///|
test "load reads a missing file as null and refuses text that is not JSON" {
  in_scratch(directory => {
    assert_eq(@jsonio.stringify(load("\{directory}/missing.json")), "null")
    write_atomic("\{directory}/broken.json", "{\"a\":")
    assert_eq(
      task_failure(() => ignore(load("\{directory}/broken.json"))),
      "\{directory}/broken.json is not valid JSON",
    )
    assert_eq(
      task_failure(() => ignore(load(directory))),
      "cannot read \{directory} (EISDIR)",
    )
  })
}

///|
test "read_records separates what was confirmed from a pending send" {
  in_scratch(directory => {
    save_json(
      "\{directory}/state.json",
      json("{\"threadId\":\"t\"}"),
      exclusive=false,
    )
    let records = read_records(directory)
    assert_eq(records.state_path, "\{directory}/state.json")
    assert_eq(records.pending_path, "\{directory}/pending.json")
    assert_eq(
      records.state.map(@jsonio.stringify),
      Some("{\"threadId\":\"t\"}"),
    )
    assert_eq(records.pending, None)
    assert_eq(@jsonio.stringify(records.loaded), "{\"threadId\":\"t\"}")
  })
}

///|
test "read_records treats empty and falsy content as no record" {
  in_scratch(directory => {
    for text in ["{}", "null", "false", "0", "\"\"", "[]"] {
      write_atomic("\{directory}/state.json", text)
      write_atomic("\{directory}/pending.json", text)
      let records = read_records(directory)
      assert_eq(records.state, None)
      assert_eq(records.pending, None)
    }
  })
}

///|
test "read_records refuses a record that is not an object" {
  in_scratch(directory => {
    for text in ["[1]", "5", "\"x\"", "true"] {
      write_atomic("\{directory}/pending.json", text)
      assert_eq(
        task_failure(() => ignore(read_records(directory))),
        "\{directory}/pending.json does not hold a JSON object",
      )
    }
    write_atomic("\{directory}/pending.json", "{")
    assert_eq(
      task_failure(() => ignore(read_records(directory))),
      "\{directory}/pending.json is not valid JSON",
    )
    write_atomic("\{directory}/state.json", "[1]")
    assert_eq(
      task_failure(() => ignore(read_records(directory))),
      "\{directory}/state.json does not hold a JSON object",
    )
  })
}

///|
test "settle_pending lets a send through when nothing is pending" {
  in_scratch(directory => {
    let records = read_records(directory)
    settle_pending(
      records,
      None,
      blocked=_ => "blocked",
      nothing_pending="none",
    )
    assert_eq(
      task_failure(() => {
        settle_pending(
          records,
          Some(Discard),
          blocked=_ => "blocked",
          nothing_pending="nothing pending",
        )
      }),
      "nothing pending",
    )
  })
}

///|
test "settle_pending blocks until the user discards the pending send" {
  in_scratch(directory => {
    save_json("\{directory}/pending.json", json("{\"id\":7}"), exclusive=true)
    let records = read_records(directory)
    let blocked = pending => "pending \{@jsonio.stringify(pending)}"
    assert_eq(
      task_failure(() => {
        settle_pending(records, None, blocked~, nothing_pending="none")
      }),
      "pending {\"id\":7}",
    )
    assert_true(is_file("\{directory}/pending.json"))
    settle_pending(records, Some(Discard), blocked~, nothing_pending="none")
    assert_false(path_exists("\{directory}/pending.json"))
    assert_eq(read_records(directory).pending, None)
  })
}

///|
test "remove_record treats a missing record as removed" {
  in_scratch(directory => remove_record("\{directory}/state.json"))
}
