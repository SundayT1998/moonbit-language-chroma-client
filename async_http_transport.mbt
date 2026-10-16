///|
/// A `ChromaClient` transport backed by `moonbitlang/async/http`.
///
/// This is the piece that turns the client's request objects into real
/// sockets. It implements `AsyncTransport`, so it plugs into the `*_async`
/// methods, and it is deliberately thin: it maps the client's
/// method/header vocabulary onto `@ah`, sends one request, and reads the
/// whole body back.
///
/// It lives in the library rather than in a test or example package because
/// a Chroma client that cannot reach a server is not useful: `preferred_target
/// = "wasm"` describes where the *client* runs, and this transport is how it
/// talks to Chroma from native and wasm alike.
///
/// One connection per request is enough for a demo and for a test suite. A
/// long-lived application that cares about latency should keep an `@ah.Client`
/// open and reuse it, because `@ah.Client` keeps the connection alive across
/// requests; see the "Native transport" section of the README.
///
/// The transport holds no state: the client already puts the full URL in
/// every request, so there is nothing to join here.
pub struct AsyncHttpTransport {}

///|
/// Builds a transport.
pub fn AsyncHttpTransport::new() -> AsyncHttpTransport {
  AsyncHttpTransport::{ }
}

///|
/// Maps the client's verb onto the HTTP stack's.
fn to_ah_method(verb : Method) -> @ah.RequestMethod {
  match verb {
    Get => @ah.RequestMethod::Get
    Post => @ah.RequestMethod::Post
    Put => @ah.RequestMethod::Put
    Delete => @ah.RequestMethod::Delete
    Patch => @ah.RequestMethod::Patch
  }
}

///|
pub impl AsyncTransport for AsyncHttpTransport with fn send_async(self, request) {
  ignore(self)
  // `@ah.Headers` is a `Map[CaseInsensitiveString, String]`, and
  // `CaseInsensitiveString` is implicitly convertible from `String`, so the
  // header names the client produced can be used as map keys unchanged.
  let headers : @ah.Headers = Map([])
  for entry in request.headers {
    let (key, value) = entry
    headers[key] = value
  }
  // A GET carries no request body in the client, and `@aio.Data` has no
  // "absent" case, so an empty byte string is the neutral value here.
  let payload : &@aio.Data = match request.body {
    Some(body) => body
    None => ""
  }
  let (response, response_body) = @ah.request(
    request.url,
    to_ah_method(request.verb),
    headers,
    payload,
  )
  let out_headers : Map[String, String] = Map([])
  for entry in response.headers {
    let (key, value) = entry
    // `Map[String, String]` is what the client's `Response` expects; the
    // original casing is not preserved by the case-insensitive key, and
    // nothing in the client reads a header by name, so lowercasing loses
    // nothing.
    out_headers[key.to_string().to_lower()] = value
  }
  { status: response.code, headers: out_headers, body: response_body.text(), }
}

///|
pub extend AsyncHttpTransport with AsyncTransport::{send_async}
