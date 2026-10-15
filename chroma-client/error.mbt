///|
/// Errors surfaced by the client.
pub(all) suberror ChromaError {
  /// The request could not be produced or sent (bad URL, transport failure).
  Transport(String)
  /// The server answered with a non-2xx status.
  Status(Int32, String)
  /// The response body was not the JSON shape this client expects.
  Decode(String)
}

///|
impl Eq for ChromaError with fn equal(self, other) {
  match (self, other) {
    (Transport(a), Transport(b)) => a == b
    (Status(a_code, a_body), Status(b_code, b_body)) =>
      a_code == b_code && a_body == b_body
    (Decode(a), Decode(b)) => a == b
    _ => false
  }
}

///|
impl Show for ChromaError with fn output(self, logger) {
  match self {
    Transport(message) => logger.write_string("transport error: " + message)
    Status(code, body) =>
      logger.write_string(
        "server returned status " + code.to_string() + ": " + body,
      )
    Decode(message) => logger.write_string("decode error: " + message)
  }
}

///|
pub extend ChromaError with Eq::{not_equal, equal}

///|
pub extend ChromaError with Show::{to_string, output}
