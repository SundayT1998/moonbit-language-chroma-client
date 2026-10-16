///|
/// Errors surfaced by the client.
pub(all) suberror ChromaError {
  /// The request could not be produced or sent (bad URL, transport failure).
  Transport(String)
  /// The server answered with a non-2xx status and a non-JSON body, or one
  /// that does not follow Chroma's error envelope.
  ///
  /// Prefer `Api` when the body is JSON: it carries the same information in
  /// parsed form. This variant stays for responses the client cannot parse.
  Status(Int32, String)
  /// The server answered with a non-2xx status and a documented error body.
  Api(ApiError)
  /// The response body was not the JSON shape this client expects.
  Decode(String)
  /// The arguments would be rejected by Chroma; nothing was sent.
  InvalidArgument(String)
}

///|
/// A non-2xx response, split into the fields Chroma documents.
///
/// Callers get the message without writing a parser or a regular expression:
/// `error` is the short machine-readable label, `message` the human sentence,
/// and `details` whatever extra structure the server attached.
pub(all) struct ApiError {
  /// HTTP status code.
  status : Int32
  /// The `error` field, e.g. `"NotFound"` or `"InternalError"`. Empty when
  /// the server omitted it.
  error_code : String
  /// The `message` field, falling back to `error` when the server sent only
  /// a label.
  message : String
  /// The unparsed body, kept so a caller can still see exactly what arrived.
  body : String
  /// Extra `details` attached to the error body.
  details : Json
} derive(Eq, Debug)

///|
/// Decodes a non-2xx body into an `ApiError`.
///
/// Chroma answers with `{"error": "...", "message": "..."}` on most paths.
/// Both fields are optional in practice: a proxy or an older server may send
/// only one, or neither, so nothing here is treated as a hard decode failure
/// and the raw body is always preserved.
pub fn ApiError::from_json(status : Int32, body : String) -> ApiError {
  let parsed = @json.parse(body.trim()) catch { _ => Json::null() }
  let fields = match parsed {
    Json::Object(fields) => Some(fields)
    _ => None
  }
  let error_code = match fields {
    Some(fields) =>
      match fields.get("error") {
        Some(Json::String(s)) => s
        _ => ""
      }
    None => ""
  }
  let message = match fields {
    Some(fields) =>
      match fields.get("message") {
        Some(Json::String(s)) => s
        _ =>
          // Some endpoints put the sentence in `error` and skip `message`.
          match fields.get("error") {
            Some(Json::String(s)) => s
            _ => ""
          }
      }
    None => ""
  }
  let details = match fields {
    Some(fields) =>
      match fields.get("details") {
        Some(value) => value
        None => Json::null()
      }
    None => Json::null()
  }
  { status, error_code, message, body, details, }
}

///|
/// Builds the error to raise for a non-2xx response.
///
/// The body is probed for the Chroma error envelope; only when it carries
/// neither `error` nor `message` does the error stay a raw `Status`.
pub fn api_error(status : Int32, body : String) -> ChromaError {
  let parsed = ApiError::from_json(status, body)
  if parsed.error_code == "" && parsed.message == "" {
    ChromaError::Status(status, body)
  } else {
    ChromaError::Api(parsed)
  }
}

///|
impl Eq for ChromaError with fn equal(self, other) {
  match (self, other) {
    (Transport(a), Transport(b)) => a == b
    (Status(a_code, a_body), Status(b_code, b_body)) =>
      a_code == b_code && a_body == b_body
    (Api(a), Api(b)) => a == b
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
    Api(error) => logger.write_string(error.to_string())
    Decode(message) => logger.write_string("decode error: " + message)
    InvalidArgument(message) =>
      logger.write_string("invalid argument: " + message)
  }
}

///|
impl Show for ApiError with fn output(self, logger) {
  logger.write_string("server returned status " + self.status.to_string())
  if self.error_code != "" {
    logger.write_string(" (" + self.error_code + ")")
  }
  if self.message != "" {
    logger.write_string(": " + self.message)
  } else if self.body.trim() != "" {
    logger.write_string(": " + self.body)
  }
}

///|
/// Extracts the numeric status of any server-side response error.
///
/// `None` means the error never reached the server, so retrying it is the
/// caller's decision rather than a given.
pub fn ChromaError::status_code(self : ChromaError) -> Int32? {
  match self {
    Status(code, _) => Some(code)
    Api(error) => Some(error.status)
    _ => None
  }
}

///|
/// Whether the error is worth retrying: 429 and 5xx, i.e. the server was
/// reachable but too busy or broken. Client errors (4xx except 429) are
/// deterministic and repeating them only wastes a round-trip.
pub fn ChromaError::is_retryable(self : ChromaError) -> Bool {
  match self.status_code() {
    Some(code) => code == 429 || (code >= 500 && code < 600)
    None => false
  }
}

///|
/// The message a caller can show a user, without the transport wrapper.
pub fn ChromaError::message(self : ChromaError) -> String {
  match self {
    Transport(text) => text
    Status(_, body) => body
    Api(error) =>
      if error.message != "" {
        error.message
      } else {
        error.error_code
      }
    Decode(text) => text
    InvalidArgument(text) => text
  }
}

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

///|
pub extend ChromaError with Eq::{not_equal, equal}

///|
pub extend ChromaError with Show::{to_string, output}

///|
pub extend ApiError with Eq::{not_equal, equal}

///|
pub extend ApiError with @debug.Debug::{to_repr}

///|
pub extend ApiError with Show::{to_string, output}
