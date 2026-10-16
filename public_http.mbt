///|
/// Re-exports the transport vocabulary so applications can implement a
/// transport without pulling in the `http` package directly.
///
/// `Transport` is the synchronous trait; `AsyncTransport` is what a real HTTP
/// stack implements, because `moonbitlang/async/http` only offers `async`
/// functions.
pub using @http {
  type Request,
  type Response,
  type Method,
  type MemoryTransport,
  trait Transport,
  trait AsyncTransport,
}

///|
/// Creates a scripted transport from a list of responses. See
/// `@http.MemoryTransport::new`.
pub fn memory_transport(responses~ : Array[Response] = []) -> MemoryTransport {
  @http.MemoryTransport::new(responses~)
}

///|
/// Builds a JSON response for `memory_transport`.
pub fn json_response(
  status : Int32,
  body : String,
  headers~ : Map[String, String] = { "content-type": "application/json" },
) -> Response {
  @http.Response::json(status, body, headers~)
}
