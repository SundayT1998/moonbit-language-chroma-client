///|
/// Errors surfaced by the client.
pub(all) suberror ChromaError {
  /// The request could not be produced or sent (bad URL, transport failure).
  Transport(String)
  /// The server answered with a non-2xx status.
  Status(Int32, String)
  /// The response body was not the JSON shape this client expects.
  Decode(String)
  /// The arguments would be rejected by Chroma; nothing was sent.
  InvalidArgument(String)
}

///|
impl Eq for ChromaError with fn equal(self, other) {
  match (self, other) {
    (Transport(a), Transport(b)) => a == b
    (Status(a_code, a_body), Status(b_code, b_body)) =>
      a_code == b_code && a_body == b_body
    (Decode(a), Decode(b)) => a == b
    (InvalidArgument(a), InvalidArgument(b)) => a == b
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
    InvalidArgument(message) =>
      logger.write_string("invalid argument: " + message)
  }
}

///|
pub extend ChromaError with Eq::{not_equal, equal}

///|
pub extend ChromaError with Show::{to_string, output}

///|
/// Validates a pagination window.
///
/// Chroma rejects a request where `offset` is not smaller than `limit`,
/// because the two are meant to walk a result set together. Catching it here
/// turns a server round-trip and an opaque 400 into a local, actionable
/// error.
pub fn validate_limit_offset(
  limit : Int32?,
  offset : Int32?,
) -> Unit raise ChromaError {
  let limit = match limit {
    Some(value) => value
    None => 0
  }
  let offset = match offset {
    Some(value) => value
    None => 0
  }
  if limit < 0 {
    raise ChromaError::InvalidArgument("limit must not be negative")
  }
  if offset < 0 {
    raise ChromaError::InvalidArgument("offset must not be negative")
  }
  if limit != 0 && offset >= limit {
    raise ChromaError::InvalidArgument(
      "offset (" +
      offset.to_string() +
      ") must be smaller than limit (" +
      limit.to_string() +
      "); Chroma cannot skip past the end of a page",
    )
  }
}
