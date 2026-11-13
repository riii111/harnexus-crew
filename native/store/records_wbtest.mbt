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
    assert_eq(load(path).stringify(), "{\"a\":[1,{\"b\":null}],\"c\":{}}")
    assert_eq(names_in("\{directory}/session"), ["state.json"])
  })
}

///|
test "save_json replaces an existing record unless it is exclusive" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"
    save_json(path, json("{\"v\":1}"), exclusive=false)
    save_json(path, json("{\"v\":2}"), exclusive=false)
    assert_eq(load(path).stringify(), "{\"v\":2}")
    assert_eq(
      task_failure(() => save_json(path, json("{\"v\":3}"), exclusive=true)),
      "another harnexus-crew run is sending; inspect \{path}",
    )
    assert_eq(load(path).stringify(), "{\"v\":2}")
  })
}

///|
test "load reads a missing file as null and refuses text that is not JSON" {
  in_scratch(directory => {
    assert_eq(load("\{directory}/missing.json").stringify(), "null")
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
      records.state.map(value => value.stringify()),
      Some("{\"threadId\":\"t\"}"),
    )
    assert_eq(records.pending, None)
    assert_eq(records.loaded.stringify(), "{\"threadId\":\"t\"}")
  })
}

///|
test "read_records treats null and an empty object as no record" {
  in_scratch(directory => {
    for text in ["{}", "null"] {
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
    for text in ["[1]", "[]", "5", "0", "\"x\"", "\"\"", "true", "false"] {
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
test "remove_record treats a missing record as removed" {
  in_scratch(directory => remove_record("\{directory}/state.json"))
}
