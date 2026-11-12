///|
test "sha256 matches the digests of Node's crypto" {
  let cases = [
    ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    (
      "a".repeat(55),
      "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
    ),
    (
      "a".repeat(56),
      "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
    ),
    (
      "a".repeat(63),
      "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
    ),
    (
      "a".repeat(64),
      "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
    ),
    (
      "a".repeat(119),
      "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
    ),
    (
      "a".repeat(120),
      "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
    ),
    (
      "/work/x\u{0}task-1", "c66dfdc6e0d5f845719a4882561544630f2a8cf8db1eb4cf295c8b40b099bf02",
    ),
    (
      "日本語", "77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5",
    ),
  ]
  for case in cases {
    assert_eq(sha256_hex(case.0), case.1)
  }
}

///|
test "sha256 hashes an unpaired surrogate as U+FFFD, as JS encodes it" {
  let lone = @jsonio.parse("\"\\ud800x\"")
  let text = match lone {
    String(text) => text
    _ => abort("not a string")
  }
  assert_eq(
    sha256_hex(text),
    "a87ce46793cc659b79bd187e998f8488635f707d5be0957e1d565981efd2b04b",
  )
}

///|
test "state_directory names a directory by the first 16 digits of the key's digest" {
  assert_eq(
    state_directory("/state/harnexus-crew", "review", "abc"),
    "/state/harnexus-crew/review/ba7816bf8f01cfea",
  )
  assert_eq(
    state_directory("/state/harnexus-crew", "launch", "/work/x\u{0}task-1"),
    "/state/harnexus-crew/launch/c66dfdc6e0d5f845",
  )
}

///|
test "new_uuid writes a version 4 UUID and does not repeat" {
  let seen : Map[String, Bool] = Map([])
  for _ in 0..<64 {
    let uuid = new_uuid()
    assert_eq(uuid.length(), 36)
    for at in [8, 13, 18, 23] {
      assert_eq(uuid[at], '-')
    }
    assert_eq(uuid[14], '4')
    assert_true(["8", "9", "a", "b"].contains(uuid[19:20].to_owned()))
    assert_false(seen.contains(uuid))
    seen[uuid] = true
  }
}

///|
test "iso_time matches Date#toISOString" {
  let cases = [
    (0L, "1970-01-01T00:00:00.000Z"),
    (1L, "1970-01-01T00:00:00.001Z"),
    (951782400000L, "2000-02-29T00:00:00.000Z"),
    (4107542400000L, "2100-03-01T00:00:00.000Z"),
    (1700000000123L, "2023-11-14T22:13:20.123Z"),
    (1767225599999L, "2025-12-31T23:59:59.999Z"),
    (1782864000000L, "2026-07-01T00:00:00.000Z"),
    (253402300799999L, "9999-12-31T23:59:59.999Z"),
    (1234567890123L, "2009-02-13T23:31:30.123Z"),
    (1709251199999L, "2024-02-29T23:59:59.999Z"),
  ]
  for case in cases {
    assert_eq(iso_time(case.0), case.1)
  }
}

///|
test "now_iso is a current UTC time" {
  let now = now_iso()
  assert_eq(now.length(), 24)
  assert_true(now.has_suffix("Z"))
  assert_true(now >= "2026-")
}

///|
test "process_alive counts this process and refuses what kill would" {
  assert_true(process_alive(current_pid().to_double()))
  assert_false(process_alive(dead_pid))
  assert_false(process_alive(1.5))
  assert_false(process_alive(2147483648.0))
  assert_false(process_alive(-2147483649.0))
  // 0 and -1 name process groups, which Node's process.kill also reports as alive.
  assert_true(process_alive(0.0))
  assert_true(process_alive(-1.0))
}
