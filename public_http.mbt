///|
/// Re-exports the transport vocabulary so applications can implement
/// `Transport` without pulling in the `http` package directly.
pub using @http {
  type Request,
  type Response,
  type Method,
  type MemoryTransport,
  trait Transport,
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
