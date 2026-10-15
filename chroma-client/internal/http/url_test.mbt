///|
test "join_url normalizes slashes" {
  assert_eq(
    @http.join_url("http://localhost:8000", "collections"),
    "http://localhost:8000/collections",
  )
  assert_eq(
    @http.join_url("http://localhost:8000/", "/collections"),
    "http://localhost:8000/collections",
  )
  assert_eq(
    @http.join_url("http://localhost:8000", ""),
    "http://localhost:8000",
  )
}

///|
test "encode_path_segment escapes reserved characters" {
  assert_eq(@http.encode_path_segment("plain-name_1.0~"), "plain-name_1.0~")
  assert_eq(@http.encode_path_segment("my collection"), "my%20collection")
  assert_eq(@http.encode_path_segment("a/b"), "a%2Fb")
}

///|
test "encode_query_component uses plus for spaces" {
  assert_eq(@http.encode_query_component("hello world"), "hello+world")
  assert_eq(@http.encode_query_component("a&b=c"), "a%26b%3Dc")
}

///|
test "append_query keeps the first separator" {
  assert_eq(
    @http.append_query("http://host/x", [("a", "1"), ("b", "2")]),
    "http://host/x?a=1&b=2",
  )
  assert_eq(
    @http.append_query("http://host/x?y=0", [("a", "1")]),
    "http://host/x?y=0&a=1",
  )
  assert_eq(@http.append_query("http://host/x", []), "http://host/x")
}

///|
test "encode_path_segment encodes non-ascii as utf8" {
  assert_eq(@http.encode_path_segment("中文"), "%E4%B8%AD%E6%96%87")
}
