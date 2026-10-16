///|
test "retry is off by default" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(200, "{\"count\":1}"),
  ])
  let transport = @chroma-client.RetryTransport::new(inner)
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.count_collections()))
  assert_true(result is Err(Api(_)))
  // exactly one request went out
  assert_eq(inner.observed().length(), 1)
}

///|
test "enabled retry re-sends 5xx until it succeeds" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(503, "{\"error\":\"Unavailable\"}"),
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(200, "{\"count\":7}"),
  ])
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(enabled=true),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.count_collections(), 7)
  assert_eq(inner.observed().length(), 3)
}

///|
test "retry re-sends 429 and reports each attempt" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(429, "{\"error\":\"TooManyRequests\"}"),
    @chroma-client.Response::json(200, "{\"ids\":[]}"),
  ])
  let attempts : Ref[Int32] = { val: 0, }
  let delays : Ref[Int32] = { val: 0, }
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(enabled=true, initial_delay_ms=100),
  ).on_retry((attempt, delay, _) => {
    attempts.val = attempt
    delays.val = delay
  })
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.get("c1").ids, [])
  assert_eq(attempts.val, 1)
  assert_eq(delays.val, 100)
}

///|
test "retry gives up after max_attempts and returns the last error" {
  // the third response is a success, but max_attempts=2 stops before it
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(200, "{\"count\":3}"),
  ])
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(enabled=true, max_attempts=2),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.count_collections()))
  assert_true(result is Err(Api(_)))
  assert_eq(inner.observed().length(), 2)
}

///|
test "retry does not re-send deterministic client errors" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(400, "{\"error\":\"BadRequest\"}"),
  ])
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(enabled=true),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.count_collections()))
  assert_true(result is Err(Api(_)))
  assert_eq(inner.observed().length(), 1)
}

///|
test "retry stamps the delay header for the next attempt" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(200, "{\"count\":1}"),
  ])
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(
      enabled=true,
      initial_delay_ms=250,
      backoff_factor=2.0,
    ),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  ignore(client.count_collections())
  let observed = inner.observed()
  assert_eq(
    observed[1].headers.get(@chroma-client.RETRY_DELAY_HEADER),
    Some("250"),
  )
}

///|
test "retry policy computes an exponential backoff with a ceiling" {
  let policy = @chroma-client.RetryPolicy::new(
    enabled=true,
    initial_delay_ms=100,
    max_delay_ms=500,
    backoff_factor=2.0,
  )
  assert_eq(policy.delay_ms(0), 100)
  assert_eq(policy.delay_ms(1), 200)
  assert_eq(policy.delay_ms(2), 400)
  // capped at max_delay_ms
  assert_eq(policy.delay_ms(3), 500)
}

///|
test "retry policy clamps nonsensical settings" {
  let policy = @chroma-client.RetryPolicy::new(
    enabled=true,
    max_attempts=0,
    initial_delay_ms=-5,
    backoff_factor=0.25,
  )
  assert_eq(policy.max_attempts, 1)
  assert_eq(policy.initial_delay_ms, 0)
  assert_eq(policy.backoff_factor, 1.0)
}

///|
test "retry composes with the timeout transport" {
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(500, "{\"error\":\"InternalError\"}"),
    @chroma-client.Response::json(200, "{\"count\":1}"),
  ])
  let transport = @chroma-client.RetryTransport::new(
    @chroma-client.TimeoutTransport::new(inner, 4000),
    policy=@chroma-client.RetryPolicy::new(enabled=true),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.count_collections(), 1)
  let observed = inner.observed()
  assert_eq(observed.length(), 2)
  assert_eq(
    observed[1].headers.get(@chroma-client.TIMEOUT_HEADER),
    Some("4000"),
  )
}

///|
test "an inner transport's parsed error is not flattened into Transport" {
  // A composed transport raises `Api`; the client must not rebrand it as a
  // transport failure, or the caller loses the status and the message.
  let inner = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(
      404, "{\"error\":\"NotFound\",\"message\":\"gone\"}",
    ),
  ])
  let transport = @chroma-client.RetryTransport::new(
    inner,
    policy=@chroma-client.RetryPolicy::new(enabled=true),
  )
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.get_collection("notes")))
  // get_collection turns a 404 into None, so nothing is raised here
  assert_true(result is Ok(_))

  let missing = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(
      409, "{\"error\":\"Conflict\",\"message\":\"exists\"}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(
    @chroma-client.RetryTransport::new(
      missing,
      policy=@chroma-client.RetryPolicy::new(enabled=true),
    ),
  )
  let result = try_catch(() => ignore(client.get_collection("notes")))
  match result {
    Err(Api(error)) => {
      assert_eq(error.status, 409)
      assert_eq(error.message, "exists")
    }
    _ => fail("expected the inner Api error to survive composition")
  }
}
