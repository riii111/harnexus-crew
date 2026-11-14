///|
async test "read_text_if_exists reports a path that cannot be read" {
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
async test "read_regular_text reads a regular file" {
  in_scratch(directory => {
    write_atomic("\{directory}/note.md", "日本語 text")

    assert_eq(read_regular_text("\{directory}/note.md"), "日本語 text")
  })
}

///|
async test "read_regular_text fails with the errno for a missing file" {
  in_scratch(directory => {
    assert_eq(
      file_failure(() => ignore(read_regular_text("\{directory}/missing.md"))),
      "cannot read \{directory}/missing.md (ENOENT)",
    )
  })
}

///|
async test "read_regular_text refuses a directory without an errno" {
  in_scratch(directory => {
    assert_eq(
      file_failure(() => ignore(read_regular_text(directory))),
      "cannot read \{directory}",
    )
  })
}

///|
async test "write_atomic replaces the content of an existing file" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    write_atomic(target, "old")
    assert_eq(read_text(target), "old")

    write_atomic(target, "new")

    assert_eq(read_text(target), "new")
  })
}

///|
async test "write_atomic leaves no temporary file beside the target" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    write_atomic(target, "old")

    write_atomic(target, "new")

    assert_eq(list_names(directory), ["state.json"])
  })
}

///|
async test "write_atomic fails when the directory is missing" {
  in_scratch(directory => {
    let failed = file_failed(() => {
      write_atomic("\{directory}/absent/x.json", "new")
    })

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
async test "write_atomic fails and keeps the target when the rename fails" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    prepare_directory("\{target}/occupied")

    let message = file_failure(() => write_atomic(target, "new"))

    assert_eq(message, "cannot write \{target} (EISDIR)")
    assert_eq(list_names(target), ["occupied"])
  })
}

///|
async test "write_atomic removes the temporary file when the rename fails" {
  in_scratch(directory => {
    let target = "\{directory}/state.json"
    prepare_directory("\{target}/occupied")

    let message = file_failure(() => write_atomic(target, "new"))

    assert_eq(message, "cannot write \{target} (EISDIR)")
    assert_eq(list_names(directory), ["state.json"])
  })
}

///|
async test "write_exclusive fails when the directory is missing" {
  in_scratch(directory => {
    assert_eq(
      file_failure(() => ignore(write_exclusive("\{directory}/absent/x", "a"))),
      "cannot write \{directory}/absent/x (ENOENT)",
    )
  })
}

///|
async test "remove_file removes an existing file" {
  in_scratch(directory => {
    write_atomic("\{directory}/gone", "x")
    assert_eq(list_names(directory), ["gone"])

    remove_file("\{directory}/gone")

    assert_eq(list_names(directory), [])
  })
}

///|
async test "remove_file treats a missing file as removed" {
  in_scratch(directory => {
    write_atomic("\{directory}/kept", "x")

    assert_eq(file_failure(() => remove_file("\{directory}/never-created")), "")
    assert_eq(list_names(directory), ["kept"])
  })
}

///|
async test "remove_file reports a directory it cannot remove" {
  in_scratch(directory => {
    let busy = "\{directory}/busy"
    prepare_directory("\{busy}/inner")

    let failed = file_failed(() => remove_file(busy))

    assert_true(failed is Some(FileFailed(action=Remove, ..)))
    assert_eq(
      failed.map(failed => plain_message(failed)),
      Some("cannot remove \{busy}"),
    )
    assert_eq(list_names(busy), ["inner"])
  })
}

///|
async test "remove_file reports a missing directory as a sync failure of the removal" {
  in_scratch(directory => {
    let failed = file_failed(() => remove_file("\{directory}/absent/x"))

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
async test "prepare_directory creates nested directories" {
  in_scratch(directory => {
    prepare_directory("\{directory}/a/b/c")

    assert_true(is_directory("\{directory}/a/b/c"))
  })
}

///|
async test "prepare_directory accepts an existing directory" {
  in_scratch(directory => {
    prepare_directory("\{directory}/a/b/c")

    assert_eq(file_failure(() => prepare_directory("\{directory}/a/b/c")), "")
    assert_true(is_directory("\{directory}/a/b/c"))
  })
}

///|
async test "prepare_directory refuses a path that is a file" {
  in_scratch(directory => {
    write_atomic("\{directory}/file", "x")

    assert_eq(
      file_failure(() => prepare_directory("\{directory}/file")),
      "cannot prepare directory \{directory}/file (EEXIST)",
    )
  })
}

///|
async test "prepare_directory refuses a path below a file" {
  in_scratch(directory => {
    write_atomic("\{directory}/file", "x")

    assert_eq(
      file_failure(() => prepare_directory("\{directory}/file/inner")),
      "cannot prepare directory \{directory}/file/inner (ENOTDIR)",
    )
  })
}

///|
async test "list_directory_if_exists lists the entry names of a directory" {
  in_scratch(directory => {
    write_atomic("\{directory}/b.json", "x")
    write_atomic("\{directory}/a.json", "x")
    prepare_directory("\{directory}/sub")

    assert_eq(list_names(directory), ["a.json", "b.json", "sub"])
  })
}

///|
async test "list_directory_if_exists returns None for a missing path or a file" {
  in_scratch(directory => {
    write_atomic("\{directory}/a.json", "x")
    assert_eq(list_directory_if_exists(directory), Some(["a.json"]))

    assert_eq(
      list_directory_if_exists("\{directory}/missing"),
      None,
      msg="missing path",
    )
    assert_eq(list_directory_if_exists("\{directory}/a.json"), None, msg="file")
  })
}

///|
async test "list_directory_if_exists retries with a larger buffer for a long listing" {
  in_scratch(directory => {
    let expected = []
    for index in 0..<200 {
      let name = "entry-\{index}-" + "x".repeat(60)
      write_atomic("\{directory}/\{name}", "x")
      expected.push(name)
    }
    expected.sort_by(String::lexical_compare)
    assert_eq(list_names(directory), expected)
  })
}

///|
async test "is_file is true only for a regular file" {
  in_scratch(directory => {
    write_atomic("\{directory}/f", "x")

    assert_true(is_file("\{directory}/f"))
    assert_false(is_file(directory))
    assert_false(is_file("\{directory}/missing"))
  })
}

///|
async test "is_directory is true only for a directory" {
  in_scratch(directory => {
    write_atomic("\{directory}/f", "x")

    assert_true(is_directory(directory))
    assert_false(is_directory("\{directory}/f"))
    assert_false(is_directory("\{directory}/missing"))
  })
}

///|
async test "path_exists is true for a file and a directory but not for a missing path or a path below a file" {
  in_scratch(directory => {
    write_atomic("\{directory}/f", "x")

    assert_true(path_exists("\{directory}/f"))
    assert_true(path_exists(directory))
    assert_false(path_exists("\{directory}/missing"))
    assert_false(path_exists("\{directory}/f/inner"))
  })
}

///|
async test "resolve_real_path_or_self follows a symbolic link to its target" {
  in_scratch(directory => {
    prepare_directory("\{directory}/target")
    @fs.symlink("\{directory}/link", target="\{directory}/target")
    let real = resolve_real_path_or_self(directory)

    assert_eq(resolve_real_path_or_self("\{directory}/link"), "\{real}/target")
  })
}

///|
async test "resolve_real_path_or_self keeps a resolved path and normalizes dot segments" {
  in_scratch(directory => {
    let real = resolve_real_path_or_self(directory)

    assert_eq(resolve_real_path_or_self(real), real)
    assert_eq(resolve_real_path_or_self("\{directory}/./sub/../"), real)
  })
}

///|
async test "resolve_real_path_or_self gives the absolute path as written when it cannot be resolved" {
  in_scratch(directory => {
    assert_eq(
      resolve_real_path_or_self("\{directory}/missing/../x"),
      @path.join(["\{directory}/x"]),
    )
  })
}

///|
fn file_failed(work : () -> Unit raise FileFailed) -> FileFailed? {
  try {
    work()
    None
  } catch {
    failed => Some(failed)
  }
}

///|
/// The message a file operation fails with, or "" when it succeeds.
fn file_failure(work : () -> Unit raise FileFailed) -> String {
  match file_failed(work) {
    Some(failed) => failed.user_message()
    None => ""
  }
}

///|
fn plain_message(failed : FileFailed) -> String {
  let FileFailed(message~, ..) = failed
  message
}
