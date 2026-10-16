///|
/// HTTP verb used by the Chroma v2 API.
pub(all) enum Method {
  Get
  Post
  Put
  Delete
  Patch
} derive(Eq, Debug)

///|
impl Show for Method with fn output(self, logger) {
  logger.write_string(
    match self {
      Get => "GET"
      Post => "POST"
      Put => "PUT"
      Delete => "DELETE"
      Patch => "PATCH"
    },
  )
}

///|
/// A fully-built HTTP request, ready to hand to a transport.
pub(all) struct Request {
  verb : Method
  url : String
  headers : Map[String, String]
  body : String?
} derive(Eq, Debug)

///|
/// The response a transport produces.
pub(all) struct Response {
  status : Int32
  headers : Map[String, String]
  body : String
} derive(Eq, Debug)

///|
/// Minimal transport abstraction.
///
/// `chroma-client` is deliberately transport-agnostic: the library builds
/// requests and decodes responses while the host application supplies the
/// actual I/O. `MemoryTransport` covers tests.
pub(open) trait Transport {
  fn send(Self, Request) -> Response raise
}

///|
/// A scripted transport for tests: records every request and replays the
/// queued responses in order.
pub(all) struct MemoryTransport {
  responses : Array[Response]
  observed : Array[Request]
  cursor : Ref[Int32]
} derive(Debug)

///|
/// Creates a `MemoryTransport` that returns the given responses in order.
pub fn MemoryTransport::new(
  responses~ : Array[Response] = [],
) -> MemoryTransport {
  { responses, observed: [], cursor: { val: 0, }, }
}

///|
pub impl Transport for MemoryTransport with fn send(self, request) {
  self.observed.push(request)
  let index = self.cursor.val
  self.cursor.val = index + 1
  if index < self.responses.length() {
    self.responses[index]
  } else {
    { status: 200, headers: {}, body: "{}", }
  }
}

///|
/// Returns the requests this transport has observed, in send order.
pub fn MemoryTransport::observed(self : MemoryTransport) -> Array[Request] {
  self.observed
}

///|
/// Returns the last observed request, if any.
pub fn MemoryTransport::last_request(self : MemoryTransport) -> Request? {
  if self.observed.length() > 0 {
    Some(self.observed[self.observed.length() - 1])
  } else {
    None
  }
}

///|
/// Convenience constructor for a scripted JSON response.
pub fn Response::json(
  status : Int32,
  body : String,
  headers~ : Map[String, String] = { "content-type": "application/json" },
) -> Response {
  { status, headers, body, }
}

///|
pub extend Method with Eq::{not_equal, equal}

///|
pub extend Method with @debug.Debug::{to_repr}

///|
pub extend Request with Eq::{not_equal, equal}

///|
pub extend Request with @debug.Debug::{to_repr}

///|
pub extend Response with Eq::{not_equal, equal}

///|
pub extend Response with @debug.Debug::{to_repr}

///|
pub extend MemoryTransport with @debug.Debug::{to_repr}

///|
pub extend MemoryTransport with Transport::{send}

///|
pub extend Method with Show::{to_string, output}
