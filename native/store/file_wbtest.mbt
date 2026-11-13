///|
test "read_text_if_exists reads a file, and a missing file is None" {
  in_scratch(directory => {
    write_atomic("\{directory}/note.txt", "text")
    assert_eq(read_text_if_exists("\{directory}/note.txt"), Some("text"))
    assert_eq(read_text_if_exists("\{directory}/missing.json"), None)
  })
}

///|
test "read_text_if_exists reports a path that cannot be read" {
  in_scratch(directory => {
    assert_eq(
      file_failure(() => ignore(read_text_if_exists(directory))),
      "cannot read \{directory} (EISDIR)",
    )
    assert_eq(
      file_failure(() => ignore(read_text_if_exists("\{directory}/a\u{0}b"))),
      "cannot read \{directory}/a\u{0}b (EINVAL)",
    )
  })
}

///|
test "read_regular_text reads a regular file and refuses anything else" {
  in_scratch(directory => {
    write_atomic("\{directory}/note.md", "日本語 text")
    assert_eq(read_regular_text("\{directory}/note.md"), "日本語 text")
    assert_eq(
      file_failure(() => ignore(read_regular_text("\{directory}/missing.md"))),
      "cannot read \{directory}/missing.md (ENOENT)",
    )
    assert_eq(
      file_failure(() => ignore(read_regular_text(directory))),
      "cannot read \{directory}",
    )
  })
}

///|
test "read_text_if_exists keeps a leading byte order mark" {
  in_scratch(directory => {
    write_atomic("\{directory}/bom.txt", "\u{FEFF}text")
    assert_eq(read_text_if_exists("\{directory}/bom.txt"), Some("\u{FEFF}text"))
  })
}

///|
test "write_atomic replaces the content and leaves no temporary file" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    write_atomic(target, "old")
    write_atomic(target, "new")
    assert_eq(read_text(target), "new")
    assert_eq(names_in(directory), ["state.json"])
  })
}

///|
test "write_atomic fails when the directory is missing" {
  in_scratch(directory => {
    let failed = try {
      write_atomic("\{directory}/absent/x.json", "new")
      None
    } catch {
      failed => Some(failed)
    }
    assert_true(
      failed is Some(FileFailed(action=Write, code=Some("ENOENT"), ..)),
    )
    assert_eq(
      failed.map(failed => failed.user_message()),
      Some("cannot write \{directory}/absent/x.json (ENOENT)"),
    )
  })
}

///|
test "write_atomic keeps the target and removes the temporary file when the rename fails" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    prepare_directory("\{target}/occupied")
    let message = file_failure(() => write_atomic(target, "new"))
    assert_true(message.has_prefix("cannot write \{target} ("))
    assert_eq(names_in(directory), ["state.json"])
    assert_eq(names_in(target), ["occupied"])
  })
}

///|
test "write_exclusive creates the file once and reports a second attempt" {
  in_scratch(directory => {
    let target = "\{directory}/lock.json"
    assert_true(write_exclusive(target, "first"))
    assert_false(write_exclusive(target, "second"))
    assert_eq(read_text(target), "first")
    assert_eq(names_in(directory), ["lock.json"])
  })
}

///|
test "write_exclusive fails when the directory is missing" {
  in_scratch(directory => {
    assert_eq(
      file_failure(() => ignore(write_exclusive("\{directory}/absent/x", "a"))),
      "cannot write \{directory}/absent/x (ENOENT)",
    )
  })
}

///|
test "remove_file treats a missing file as removed and reports one that cannot be removed" {
  in_scratch(directory => {
    write_atomic("\{directory}/gone", "x")
    remove_file("\{directory}/gone")
    remove_file("\{directory}/never-created")
    assert_eq(names_in(directory), [])
    prepare_directory("\{directory}/busy/inner")
    let failed = try {
      remove_file("\{directory}/busy")
      None
    } catch {
      failed => Some(failed)
    }
    assert_true(failed is Some(FileFailed(action=Remove, ..)))
  })
}

///|
test "remove_file reports a missing directory as a sync failure of the removal" {
  in_scratch(directory => {
    let failed = try {
      remove_file("\{directory}/absent/x")
      None
    } catch {
      failed => Some(failed)
    }
    assert_true(
      failed is Some(FileFailed(action=Sync, code=Some("ENOENT"), ..)),
    )
    assert_eq(
      failed.map(failed => failed.user_message()),
      Some(
        "removed \{directory}/absent/x but cannot sync its directory (ENOENT)",
      ),
    )
  })
}

///|
test "prepare_directory creates nested directories, accepts an existing one and refuses a file" {
  in_scratch(directory => {
    prepare_directory("\{directory}/a/b/c")
    prepare_directory("\{directory}/a/b/c")
    assert_true(is_directory("\{directory}/a/b/c"))
    write_atomic("\{directory}/file", "x")
    assert_eq(
      file_failure(() => prepare_directory("\{directory}/file")),
      "cannot prepare directory \{directory}/file (EEXIST)",
    )
    assert_eq(
      file_failure(() => prepare_directory("\{directory}/file/inner")),
      "cannot prepare directory \{directory}/file/inner (ENOTDIR)",
    )
  })
}

///|
test "list_directory_if_exists lists names, and None for a missing path or a file" {
  in_scratch(directory => {
    write_atomic("\{directory}/b.json", "x")
    write_atomic("\{directory}/a.json", "x")
    prepare_directory("\{directory}/sub")
    assert_eq(names_in(directory), ["a.json", "b.json", "sub"])
    assert_eq(list_directory_if_exists("\{directory}/missing"), None)
    assert_eq(list_directory_if_exists("\{directory}/a.json"), None)
  })
}

///|
test "list_directory_if_exists retries with a larger buffer for a long listing" {
  in_scratch(directory => {
    let expected = []
    for index in 0..<200 {
      let name = "entry-\{index}-" + "x".repeat(60)
      write_atomic("\{directory}/\{name}", "x")
      expected.push(name)
    }
    expected.sort_by(String::lexical_compare)
    assert_eq(names_in(directory), expected)
  })
}

///|
test "is_file, is_directory and path_exists tell the kind of a path" {
  in_scratch(directory => {
    write_atomic("\{directory}/f", "x")
    assert_true(is_file("\{directory}/f"))
    assert_false(is_directory("\{directory}/f"))
    assert_true(is_directory(directory))
    assert_false(is_file(directory))
    assert_true(path_exists("\{directory}/f"))
    assert_false(path_exists("\{directory}/missing"))
    assert_false(path_exists("\{directory}/f/inner"))
  })
}

///|
test "real_path_or_self gives an absolute path, resolved when it exists" {
  in_scratch(directory => {
    let real = real_path_or_self(directory)
    assert_eq(real_path_or_self(real), real)
    assert_eq(real_path_or_self("\{directory}/./sub/../"), real)
    assert_eq(
      real_path_or_self("\{directory}/missing/../x"),
      @path.normalize("\{directory}/x"),
    )
  })
}
