///|
test "api error splits the chroma error envelope" {
  let error = @chroma-client.ApiError::from_json(
    400, "{\"error\":\"BadRequest\",\"message\":\"Expected ids to be unique\"}",
  )
  assert_eq(error.status, 400)
  assert_eq(error.error_code, "BadRequest")
  assert_eq(error.message, "Expected ids to be unique")
}

///|
test "api error falls back to error when message is missing" {
  let error = @chroma-client.ApiError::from_json(
    404, "{\"error\":\"NotFound\"}",
  )
  assert_eq(error.error_code, "NotFound")
  // the label is the best sentence available, so it doubles as the message
  assert_eq(error.message, "NotFound")
}

///|
test "api error keeps the raw body and details" {
  let raw = "{\"error\":\"UnprocessableEntity\",\"message\":\"bad record\",\"details\":{\"index\":3}}"
  let error = @chroma-client.ApiError::from_json(422, raw)
  assert_eq(error.body, raw)
  assert_eq(error.details, @json.parse("{\"index\":3}"))
}

///|
test "api error tolerates a body without the envelope" {
  let error = @chroma-client.ApiError::from_json(502, "upstream boom")
  assert_eq(error.error_code, "")
  assert_eq(error.message, "")
  assert_eq(error.body, "upstream boom")
}

///|
test "api_error routes enveloped bodies to Api and raw bodies to Status" {
  assert_true(
    @chroma-client.api_error(500, "{\"error\":\"InternalError\"}") is Api(_),
  )
  assert_true(
    @chroma-client.api_error(500, "<html>gateway</html>") is Status(500, _),
  )
  assert_true(@chroma-client.api_error(500, "") is Status(500, _))
}

///|
test "status_code and is_retryable classify server responses" {
  assert_eq(
    @chroma-client.api_error(404, "{\"error\":\"NotFound\"}").status_code(),
    Some(404),
  )
  assert_eq(@chroma-client.ChromaError::Transport("boom").status_code(), None)
  // 429 and 5xx are transient, other client errors are not
  assert_true(
    @chroma-client.api_error(429, "{\"error\":\"TooMany\"}").is_retryable(),
  )
  assert_true(@chroma-client.ChromaError::Status(503, "").is_retryable())
  assert_true(
    !@chroma-client.api_error(400, "{\"error\":\"Bad\"}").is_retryable(),
  )
  assert_true(!@chroma-client.ChromaError::Transport("boom").is_retryable())
}

///|
test "message returns the sentence a caller would show a user" {
  assert_eq(
    @chroma-client.api_error(
      400, "{\"error\":\"BadRequest\",\"message\":\"duplicate ids\"}",
    ).message(),
    "duplicate ids",
  )
  assert_eq(
    @chroma-client.ChromaError::InvalidArgument("nope").message(),
    "nope",
  )
}

///|
test "Show renders the parsed error without the raw body wrapper" {
  let text = @chroma-client.api_error(
    409, "{\"error\":\"Conflict\",\"message\":\"collection exists\"}",
  ).to_string()
  assert_eq(text, "server returned status 409 (Conflict): collection exists")
}

///|
test "get_collection still reports non-404 failures" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.get_collection("notes")))
  assert_true(result is Err(Api(_)))
}

///|
test "error bodies reach the caller intact on every endpoint" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(
      422, "{\"error\":\"UnprocessableEntity\",\"message\":\"bad embedding\"}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.query_embeddings("c1", [[1.0]])))
  match result {
    Err(Api(error)) => {
      assert_eq(error.status, 422)
      assert_eq(error.error_code, "UnprocessableEntity")
      assert_eq(error.message, "bad embedding")
    }
    _ => fail("expected an Api error")
  }
}
