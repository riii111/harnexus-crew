///|
async test "save_json writes the record with one space of indent" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"

    save_json(path, json("{\"a\":[1,{\"b\":null}],\"c\":{}}"), exclusive=false)

    assert_eq(
      read_text(path),
      "{\n \"a\": [\n  1,\n  {\n   \"b\": null\n  }\n ],\n \"c\": {}\n}",
    )
  })
}

///|
async test "save_json creates a missing parent directory and leaves only the record in it" {
  in_scratch(directory => {
    let path = "\{directory}/session/state.json"

    save_json(path, json("{\"v\":1}"), exclusive=false)

    assert_eq(list_names("\{directory}/session"), ["state.json"])
  })
}

///|
async test "read_json_or_null reads back a saved record" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"

    save_json(path, json("{\"a\":[1,{\"b\":null}],\"c\":{}}"), exclusive=false)

    assert_eq(
      read_json_or_null(path).stringify(),
      "{\"a\":[1,{\"b\":null}],\"c\":{}}",
    )
  })
}

///|
async test "save_json replaces an existing record when it is not exclusive" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"

    save_json(path, json("{\"v\":1}"), exclusive=false)

    assert_eq(read_json_or_null(path).stringify(), "{\"v\":1}")

    save_json(path, json("{\"v\":2}"), exclusive=false)

    assert_eq(read_json_or_null(path).stringify(), "{\"v\":2}")
  })
}

///|
async test "save_json refuses to replace an existing record when it is exclusive" {
  in_scratch(directory => {
    let path = "\{directory}/state.json"

    save_json(path, json("{\"v\":1}"), exclusive=false)

    assert_eq(read_json_or_null(path).stringify(), "{\"v\":1}")

    assert_eq(
      task_failure(() => save_json(path, json("{\"v\":3}"), exclusive=true)),
      "another harnexus-crew run is sending; inspect \{path}",
    )

    assert_eq(read_json_or_null(path).stringify(), "{\"v\":1}")
  })
}

///|
async test "read_json_or_null reads a missing file as null" {
  in_scratch(directory => {
    assert_eq(
      read_json_or_null("\{directory}/missing.json").stringify(),
      "null",
    )
  })
}

///|
async test "read_json_or_null refuses text that is not JSON" {
  in_scratch(directory => {
    write_atomic("\{directory}/broken.json", "{\"a\":")

    assert_eq(
      task_failure(() => ignore(read_json_or_null("\{directory}/broken.json"))),
      "\{directory}/broken.json is not valid JSON",
    )
  })
}

///|
async test "read_json_or_null refuses a path that cannot be read" {
  in_scratch(directory => {
    assert_eq(
      task_failure(() => ignore(read_json_or_null(directory))),
      "cannot read \{directory} (EISDIR)",
    )
  })
}

///|
async test "read_records separates what was confirmed from a pending send" {
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
async test "read_records treats null and an empty object as no record" {
  in_scratch(directory => {
    for text in ["{}", "null"] {
      write_atomic("\{directory}/state.json", text)
      write_atomic("\{directory}/pending.json", text)

      let records = read_records(directory)

      assert_eq(records.state, None, msg=text)
      assert_eq(records.pending, None, msg=text)
    }
  })
}

///|
async test "read_records refuses a pending record that is not an object" {
  in_scratch(directory => {
    for text in ["[1]", "[]", "5", "0", "\"x\"", "\"\"", "true", "false"] {
      write_atomic("\{directory}/pending.json", text)

      assert_eq(
        task_failure(() => ignore(read_records(directory))),
        "\{directory}/pending.json does not hold a JSON object",
        msg=text,
      )
    }
  })
}

///|
async test "read_records refuses a state record that is not an object" {
  in_scratch(directory => {
    write_atomic("\{directory}/state.json", "[1]")

    assert_eq(
      task_failure(() => ignore(read_records(directory))),
      "\{directory}/state.json does not hold a JSON object",
    )
  })
}

///|
async test "read_records refuses a pending record that is not JSON" {
  in_scratch(directory => {
    write_atomic("\{directory}/pending.json", "{")

    assert_eq(
      task_failure(() => ignore(read_records(directory))),
      "\{directory}/pending.json is not valid JSON",
    )
  })
}

///|
fn json(text : String) -> Json {
  @jsonio.parse(text) catch {
    _ => abort("not JSON: \{text}")
  }
}
