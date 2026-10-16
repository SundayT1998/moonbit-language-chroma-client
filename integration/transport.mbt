///|
/// Sends the client's requests over `moonbitlang/async/http`.
///
/// The integration tests talk to a real Chroma server, so they need a real
/// transport rather than `MemoryTransport`'s scripted replies. It is the same
/// shape as the one in `examples/native`, kept local so the test suite does
/// not depend on an example package.
struct LiveTransport {}

///|
fn LiveTransport::new() -> LiveTransport {
  LiveTransport::{ }
}

///|
fn to_ah_method(verb : @chttp.Method) -> @ah.RequestMethod {
  match verb {
    @chttp.Get => @ah.RequestMethod::Get
    @chttp.Post => @ah.RequestMethod::Post
    @chttp.Put => @ah.RequestMethod::Put
    @chttp.Delete => @ah.RequestMethod::Delete
    @chttp.Patch => @ah.RequestMethod::Patch
  }
}

///|
impl @chttp.AsyncTransport for LiveTransport with fn send_async(self, request) {
  ignore(self)
  let headers : @ah.Headers = Map([])
  for entry in request.headers {
    let (key, value) = entry
    headers[key] = value
  }
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
    out_headers[key.to_string().to_lower()] = value
  }
  { status: response.code, headers: out_headers, body: response_body.text(), }
}

///|
pub extend LiveTransport with @chttp.AsyncTransport::{send_async}
