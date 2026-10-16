///|
/// Serverless doubles for the asynchronous half of the client.
///
/// `MemoryTransport` cannot serve the `_async` methods: they take an
/// `AsyncTransport`, and an `async` call cannot be made from a synchronous
/// implementation. These live here, in a whitebox test file, rather than in
/// the library, because they are only useful to tests — unlike
/// `MemoryTransport`, which is documented API for anyone embedding the client
/// without a network.
///
/// A whitebox file can see them, a blackbox one cannot, so the tests that use
/// them are `*_wbtest.mbt` too.

///|
/// Replays scripted responses and records every request, so the `_async`
/// methods can be driven from a test without a server.
///
/// Requests are stored in a `Ref` because `send_async` takes `Self` by value:
/// the recorded requests have to outlive the copy the trait method receives.
struct ScriptedAsyncTransport {
  responses : Array[Response]
  observed : Ref[Array[Request]]
  cursor : Ref[Int32]
}

///|
/// Creates a `ScriptedAsyncTransport` that returns the given responses in
/// order, then `{"status":200,"body":"{}"}` for every further request.
fn ScriptedAsyncTransport::new(
  responses~ : Array[Response] = [],
) -> ScriptedAsyncTransport {
  { responses, observed: { val: [], }, cursor: { val: 0, }, }
}

///|
/// Returns the requests this transport has observed, in send order.
fn ScriptedAsyncTransport::observed(
  self : ScriptedAsyncTransport,
) -> Array[Request] {
  self.observed.val
}

///|
/// Returns the last observed request, if any.
fn ScriptedAsyncTransport::last_request(
  self : ScriptedAsyncTransport,
) -> Request? {
  let observed = self.observed.val
  if observed.length() > 0 {
    Some(observed[observed.length() - 1])
  } else {
    None
  }
}

///|
impl AsyncTransport for ScriptedAsyncTransport with fn send_async(self, request) {
  self.observed.val.push(request)
  let index = self.cursor.val
  self.cursor.val = index + 1
  if index < self.responses.length() {
    self.responses[index]
  } else {
    { status: 200, headers: {}, body: "{}", }
  }
}

///|
/// A transport that always raises a chosen error, so the client's
/// pass-through mapping can be tested without a socket.
///
/// The client promises that an error an inner transport already classified
/// (`Transport`, `Status`, `Api`, `Decode`, `InvalidArgument`) is re-raised
/// unchanged rather than flattened, and that anything else becomes a
/// `Transport` error. A refused connection is not reachable in a serverless
/// test, so this double raises the error directly.
struct FailingAsyncTransport {
  error : ChromaError
}

///|
/// Creates a transport that raises `error` on every request.
fn FailingAsyncTransport::new(
  error~ : ChromaError = ChromaError::Transport("connection refused"),
) -> FailingAsyncTransport {
  { error, }
}

///|
impl AsyncTransport for FailingAsyncTransport with fn send_async(self, request) {
  ignore(request)
  raise self.error
}

///|
/// The synchronous counterpart of `FailingAsyncTransport`, for the same
/// reason: `MemoryTransport` cannot be made to raise.
struct FailingTransport {
  error : ChromaError
}

///|
/// Creates a transport that raises `error` on every request.
fn FailingTransport::new(
  error~ : ChromaError = ChromaError::Transport("connection refused"),
) -> FailingTransport {
  { error, }
}

///|
impl Transport for FailingTransport with fn send(self, request) {
  ignore(request)
  raise self.error
}
