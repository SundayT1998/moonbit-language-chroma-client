///|
/// Sends the client's requests over `moonbitlang/async/http`.
///
/// The integration tests talk to a real Chroma server, so they need a real
/// transport rather than `MemoryTransport`'s scripted replies. It is the same
/// shape as the one in `cmd/main`, kept local so the test suite does
/// not depend on an example package.
struct LiveTransport {}

///|
fn LiveTransport::new() -> LiveTransport {
  LiveTransport::{ }
}

///|
fn to_ah_method(verb : @chroma.Method) -> @ah.RequestMethod {
  match verb {
    @chroma.Get => @ah.RequestMethod::Get
    @chroma.Post => @ah.RequestMethod::Post
    @chroma.Put => @ah.RequestMethod::Put
    @chroma.Delete => @ah.RequestMethod::Delete
    @chroma.Patch => @ah.RequestMethod::Patch
  }
}

///|
impl @chroma.AsyncTransport for LiveTransport with fn send_async(self, request) {
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
pub extend LiveTransport with @chroma.AsyncTransport::{send_async}
