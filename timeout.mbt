///|
/// Wraps a transport so that every request carries a deadline.
///
/// The library never performs I/O itself, so it cannot enforce a timeout on
/// its own: cancelling a socket read is a property of the HTTP stack, not of
/// the request. This wrapper makes the promise explicit instead. It stamps
/// `x-chroma-timeout-ms` on each request and hands it to the inner transport,
/// so a real transport can honour the value; a transport that ignores the
/// header still works, it just loses the guarantee.
///
/// ```text
/// let client = ChromaClient::new(TimeoutTransport::new(http_stack, 5000))
/// ```
pub(all) struct TimeoutTransport[T] {
  inner : T
  timeout_ms : Int32
}

///|
/// Wraps `inner`, limiting each request to `timeout_ms` milliseconds.
///
/// A non-positive value means "no deadline", in which case only the header
/// stamping is skipped and requests pass through untouched.
pub fn[T] TimeoutTransport::new(
  inner : T,
  timeout_ms : Int32,
) -> TimeoutTransport[T] {
  { inner, timeout_ms, }
}

///|
/// Builds a timeout transport from a client's own configuration, so
/// `Config::timeout_ms` gets a consumer.
pub fn[T] TimeoutTransport::from_config(
  inner : T,
  config : Config,
) -> TimeoutTransport[T] {
  { inner, timeout_ms: config.timeout_ms, }
}

///|
/// The header a transport reads to learn its deadline.
pub const TIMEOUT_HEADER : String = "x-chroma-timeout-ms"

///|
pub impl[T : Transport] Transport for TimeoutTransport[T] with fn send(
  self,
  request,
) {
  if self.timeout_ms <= 0 {
    return self.inner.send(request)
  }
  let headers = request.headers.copy()
  headers[TIMEOUT_HEADER] = self.timeout_ms.to_string()
  self.inner.send({ ..request, headers, })
}

///|
pub extend TimeoutTransport with Transport::{send}
