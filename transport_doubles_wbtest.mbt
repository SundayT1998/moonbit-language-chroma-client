///|
/// Tests for the serverless transport doubles and the client's error
/// pass-through.
///
/// These use the private doubles in `scripted_transport_wbtest.mbt`, so they
/// live in a whitebox file too. The point of each one is the client's
/// contract: which error variants survive a transport round-trip unchanged,
/// and which are re-wrapped.

///|
test "an error raised by an inner transport keeps its shape" {
  // A composed transport (retry, timeout) classifies the error before the
  // client sees it. Flattening it into `Transport` would hide the status.
  let transport = FailingTransport::new(
    error=ChromaError::Status(503, "gateway"),
  )
  let client = ChromaClient::new(transport)
  let result = try {
    ignore(client.heartbeat())
    None
  } catch {
    error => Some(error)
  }
  assert_true(result is Some(Status(503, _)))
}

///|
test "an unclassified transport failure becomes a Transport error" {
  let transport = FailingTransport::new(
    error=ChromaError::Transport("connection refused"),
  )
  let client = ChromaClient::new(transport)
  let result = try {
    ignore(client.heartbeat())
    None
  } catch {
    error => Some(error)
  }
  match result {
    Some(Transport(message)) => assert_eq(message, "connection refused")
    _ => fail("expected a Transport error")
  }
}

///|
test "a decode error from a transport is re-raised unchanged" {
  // The catch-all arm exists so a transport that raises something the client
  // does not know about still reaches the caller as a `ChromaError`.
  let transport = FailingTransport::new(error=ChromaError::Decode("bad shape"))
  let client = ChromaClient::new(transport)
  let result = try {
    ignore(client.heartbeat())
    None
  } catch {
    error => Some(error)
  }
  assert_true(result is Some(Decode(_)))
}

///|
test "the scripted transport reports an empty history" {
  let transport = ScriptedAsyncTransport::new()
  assert_eq(transport.observed().length(), 0)
  assert_true(transport.last_request() is None)
}
