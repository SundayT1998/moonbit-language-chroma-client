///|
/// A Chroma client bound to one transport and one server configuration.
///
/// The client is generic over its transport so applications can plug in any
/// HTTP implementation, and tests can use
/// `@http.MemoryTransport`. It is otherwise stateless: every call is a plain
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
  @http.join_url(self.config.endpoint, "/api/v2/" + path)
}

///|
/// The `/tenants/{tenant}/databases/{database}` prefix shared by every
/// resource endpoint, with dynamic segments percent-encoded.
fn[T] ChromaClient::database_prefix(self : ChromaClient[T]) -> String {
  let tenant = @http.encode_path_segment(self.config.tenant)
  let database = @http.encode_path_segment(self.config.database)
  "tenants/" + tenant + "/databases/" + database
}

///|
/// Sends a request through the transport, mapping non-2xx responses to
/// `ChromaError::Status` and transport failures to
/// `ChromaError::Transport`.
fn[T : @http.Transport] ChromaClient::send(
  self : ChromaClient[T],
  verb : @http.Method,
  path : String,
  body~ : Json = Json::null(),
) -> @http.Response raise ChromaError {
  let headers : Map[String, String] = { "content-type": "application/json" }
  for entry in self.config.headers {
    let (key, value) = entry
    headers[key] = value
  }
  let payload = match verb {
    @http.Get | @http.Delete => None
    _ => Some(body.stringify())
  }
  let request : @http.Request = {
    verb,
    url: self.api_url(path),
    headers,
    body: payload,
  }
  let response = self.transport.send(request) catch {
    error => raise ChromaError::Transport(error.to_string())
  }
  if response.status < 200 || response.status >= 300 {
    raise ChromaError::Status(response.status, response.body)
  }
  response
}

///|
/// Sends a request and parses the response body as JSON.
fn[T : @http.Transport] ChromaClient::send_json(
  self : ChromaClient[T],
  verb : @http.Method,
  path : String,
  body~ : Json = Json::null(),
) -> Json raise ChromaError {
  let response = self.send(verb, path, body~)
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
/// Reads a required integer field.
fn required_int(json : Json, key : String) -> Int32 raise ChromaError {
  let value = required_object(json, key)
  match value {
    Json::Number(n, ..) => n.to_int()
    Json::String(s) =>
      @string.parse_int(s) catch {
        _ =>
          raise ChromaError::Decode("field \"" + key + "\" is not an integer")
      }
    _ => raise ChromaError::Decode("field \"" + key + "\" is not an integer")
  }
}

///|
/// Reads an optional string field, defaulting to `""`.

///|
/// Reads a required array field.

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
  self.database_prefix() +
  "/collections/" +
  @http.encode_path_segment(collection_id)
}

///|
/// Checks that the server is reachable and returns its version string.
pub fn[T : @http.Transport] ChromaClient::heartbeat(
  self : ChromaClient[T],
) -> Int32 raise ChromaError {
  let response = self.send_json(@http.Get, "heartbeat")
  match response {
    Json::Number(n, ..) => n.to_int()
    _ => 0
  }
}

///|
/// Returns the server version string.
pub fn[T : @http.Transport] ChromaClient::version(
  self : ChromaClient[T],
) -> String raise ChromaError {
  let response = self.send_json(@http.Get, "version")
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
