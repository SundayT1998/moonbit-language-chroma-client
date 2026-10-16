///|
/// A Chroma client bound to one transport and one server configuration.
///
/// The client is generic over its transport so applications can plug in any
/// HTTP implementation, and tests can use
/// `MemoryTransport`. It is otherwise stateless: every call is a plain
/// HTTP request.
pub(all) struct ChromaClient[T] {
  transport : T
  config : Config
}

///|
/// Binds a transport and configuration into a client.
pub fn[T] ChromaClient::new(
  transport : T,
  config~ : Config = Config::new(),
) -> ChromaClient[T] {
  { transport, config, }
}

///|
/// Builds the URL for a versioned API path, e.g. `/collections`.
fn[T] ChromaClient::api_url(self : ChromaClient[T], path : String) -> String {
  join_url(self.config.endpoint, "/api/v2/" + path)
}

///|
/// The `/tenants/{tenant}/databases/{database}` prefix shared by every
/// resource endpoint, with dynamic segments percent-encoded.
fn[T] ChromaClient::database_prefix(self : ChromaClient[T]) -> String {
  let tenant = encode_path_segment(self.config.tenant)
  let database = encode_path_segment(self.config.database)
  "tenants/" + tenant + "/databases/" + database
}

///|
/// The largest response body the client will decode.
///
/// The client reads a whole body into one `String`, and MoonBit strings are
/// UTF-8, so the limit is stated in bytes: 32 MiB is far above any realistic
/// result set (a full `Include::all()` page of 1024-dimension vectors is a
/// few megabytes) yet small enough that a runaway response cannot exhaust
/// memory before the caller sees an error.
///
/// Truncating is not an option, because a half-parsed result set would look
/// like data loss. A response past the limit fails loudly instead, and the
/// caller can narrow `include`, lower `n_results` or page with `limit`.
pub const MAX_RESPONSE_BYTES : Int32 = 32 * 1024 * 1024

///|
/// Sends a request through the transport, mapping non-2xx responses to
/// `ChromaError::Api` / `ChromaError::Status` and transport failures to
/// `ChromaError::Transport`.
fn[T : Transport] ChromaClient::send(
  self : ChromaClient[T],
  verb : Method,
  path : String,
  body~ : Json = Json::null(),
) -> Response raise ChromaError {
  let headers : Map[String, String] = { "content-type": "application/json" }
  for entry in self.config.headers {
    let (key, value) = entry
    headers[key] = value
  }
  let payload = match verb {
    Get | Delete => None
    _ => Some(body.stringify())
  }
  let request : Request = {
    verb,
    url: self.api_url(path),
    headers,
    body: payload,
  }
  let response = self.transport.send(request) catch {
    // Transports may be composed (timeout, retry), and an inner transport
    // can raise an error this client already understands: re-raise those
    // unchanged rather than flattening them into `Transport`, which would
    // hide the status and the parsed message from the caller.
    ChromaError::Api(_) as error => raise error
    ChromaError::Status(_, _) as error => raise error
    ChromaError::Decode(_) as error => raise error
    ChromaError::InvalidArgument(_) as error => raise error
    ChromaError::Transport(_) as error => raise error
    error => raise ChromaError::Transport(error.to_string())
  }
  if response.status < 200 || response.status >= 300 {
    raise api_error(response.status, response.body)
  }
  guard_response_body(response)
  response
}

///|
/// Rejects a body the client refuses to materialize as JSON.
///
/// The check lives outside `send`'s parse step so every decoding path shares
/// it, and so error responses (which are short by construction) are never
/// rejected for size before their message can be read.
fn guard_response_body(response : Response) -> Unit raise ChromaError {
  if response.body.length() > MAX_RESPONSE_BYTES {
    raise ChromaError::Decode(
      "response body is " +
      response.body.length().to_string() +
      " bytes, above the " +
      MAX_RESPONSE_BYTES.to_string() +
      " byte limit; narrow `include` or page with `limit`",
    )
  }
}

///|
/// Sends a request and parses the response body as JSON.
fn[T : Transport] ChromaClient::send_json(
  self : ChromaClient[T],
  verb : Method,
  path : String,
  body~ : Json = Json::null(),
) -> Json raise ChromaError {
  self.response_json_or_null(self.send(verb, path, body~))
}

///|
/// Parses an already-fetched response body, applying the size guard first.
///
/// Callers that hand the body to a hand-written decoder rather than to the
/// generic one use this so the limit is enforced in exactly one place.
fn[T] ChromaClient::response_json_or_null(
  self : ChromaClient[T],
  response : Response,
) -> Json raise ChromaError {
  ignore(self)
  guard_response_body(response)
  if response.body.trim().length() == 0 {
    return Json::null()
  }
  @json.parse(response.body) catch {
    error =>
      raise ChromaError::Decode("invalid JSON response: " + error.to_string())
  }
}

///|
/// Reads a required object field, reporting a decode error when it is
/// missing or not an object.
fn required_object(json : Json, key : String) -> Json raise ChromaError {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None =>
          raise ChromaError::Decode("response is missing field \"" + key + "\"")
      }
    _ => raise ChromaError::Decode("expected a JSON object")
  }
}

///|
/// Reads a required string field.
fn required_string(json : Json, key : String) -> String raise ChromaError {
  let value = required_object(json, key)
  match value {
    Json::String(s) => s
    _ => raise ChromaError::Decode("field \"" + key + "\" is not a string")
  }
}

///|
/// Reads a count response.
///
/// Chroma's count endpoints answer with a bare integer
/// (`GET /collections/{id}/count` returns `3`, not `{"count": 3}`). A
/// `{"count": n}` envelope is accepted too, so a server that wraps the value
/// still decodes.
fn decode_count(json : Json, endpoint : String) -> Int32 raise ChromaError {
  match json {
    Json::Number(n, ..) => n.to_int()
    Json::Object(fields) =>
      match fields.get("count") {
        Some(Json::Number(n, ..)) => n.to_int()
        Some(Json::String(s)) =>
          @string.parse_int(s) catch {
            _ =>
              raise ChromaError::Decode(
                endpoint + " returned a non-numeric count",
              )
          }
        _ =>
          raise ChromaError::Decode(
            endpoint + " response has no \"count\" field",
          )
      }
    _ => raise ChromaError::Decode(endpoint + " did not return a count")
  }
}

///|
/// Reads a required array field, reporting a decode error when it is
/// missing or not an array.
fn required_array(json : Json, key : String) -> Array[Json] raise ChromaError {
  match required_object(json, key) {
    Json::Array(items) => items
    _ => raise ChromaError::Decode("field \"" + key + "\" is not an array")
  }
}

///|
/// Reads an optional array field, defaulting to an empty array.
fn optional_array(json : Json, key : String) -> Array[Json] {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
/// Reads an optional `Map`, defaulting to `Map([])`.
fn optional_object(json : Json, key : String) -> Json {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => Json::empty_object()
      }
    _ => Json::empty_object()
  }
}

///|
/// Builds the URL path for a collection-scoped endpoint.
///
/// Chroma v2 addresses a collection by its id, which is a UUID and may
/// therefore be treated as a plain path segment.
fn[T] ChromaClient::collection_path(
  self : ChromaClient[T],
  collection_id : String,
) -> String {
  self.database_prefix() + "/collections/" + encode_path_segment(collection_id)
}

///|
/// Checks that the server is reachable and returns its heartbeat timestamp.
///
/// Chroma answers `{"nanosecond heartbeat": <ns since the epoch>}`. The
/// nanoseconds do not fit an `Int32`, so the value is returned as an `Int64`;
/// a server that answers with a bare number (or with an unexpected shape) is
/// accepted too, since the point of the call is reachability rather than the
/// timestamp itself.
pub fn[T : Transport] ChromaClient::heartbeat(
  self : ChromaClient[T],
) -> Int64 raise ChromaError {
  self.heartbeat_value(self.send_json(Get, "heartbeat"))
}

///|
/// Reads a heartbeat response, tolerating both the documented envelope and a
/// bare number.
fn[T] ChromaClient::heartbeat_value(
  self : ChromaClient[T],
  response : Json,
) -> Int64 raise ChromaError {
  ignore(self)
  let (key, value) = match response {
    Json::Object(fields) =>
      // `"nanosecond heartbeat"` is the documented key; fall back to the
      // first field so a renamed envelope still yields a number.
      match fields.get("nanosecond heartbeat") {
        Some(value) => ("nanosecond heartbeat", value)
        None =>
          match fields.iter().next() {
            Some(entry) => entry
            None => ("", Json::null())
          }
      }
    other => ("", other)
  }
  ignore(key)
  match value {
    Json::Number(n, ..) => n.to_int64()
    Json::String(s) =>
      @string.parse_int64(s) catch {
        _ => raise ChromaError::Decode("heartbeat is not an integer")
      }
    _ =>
      raise ChromaError::Decode(
        "heartbeat response is not an object with a nanosecond timestamp",
      )
  }
}

///|
/// Returns the server version string.
pub fn[T : Transport] ChromaClient::version(
  self : ChromaClient[T],
) -> String raise ChromaError {
  let response = self.send_json(Get, "version")
  match response {
    Json::String(s) => s
    _ => ""
  }
}

///|
/// Returns the configuration this client was built with.
pub fn[T] ChromaClient::config(self : ChromaClient[T]) -> Config {
  self.config
}
