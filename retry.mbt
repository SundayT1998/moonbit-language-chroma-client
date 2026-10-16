///|
/// Retry policy for `RetryTransport`.
///
/// Retrying is never implicit: nothing is retried until a `RetryTransport`
/// is built with `enabled: true`, so a plain client keeps the "one call, one
/// request" behaviour.
pub(all) struct RetryPolicy {
  /// Whether to retry at all. `false` makes the transport a pass-through.
  enabled : Bool
  /// Total attempts per request, including the first one. Minimum 1.
  max_attempts : Int32
  /// Delay before the first retry, in milliseconds.
  initial_delay_ms : Int32
  /// Ceiling for the delay, in milliseconds.
  max_delay_ms : Int32
  /// Multiplier applied to the delay after each attempt.
  backoff_factor : Double
} derive(Eq, Debug)

///|
/// Builds a retry policy. `enabled` defaults to `false`, so the caller has
/// to opt in to the retry behaviour.
pub fn RetryPolicy::new(
  enabled~ : Bool = false,
  max_attempts~ : Int32 = 3,
  initial_delay_ms~ : Int32 = 200,
  max_delay_ms~ : Int32 = 5000,
  backoff_factor~ : Double = 2.0,
) -> RetryPolicy {
  {
    enabled,
    max_attempts: if max_attempts < 1 {
      1
    } else {
      max_attempts
    },
    initial_delay_ms: if initial_delay_ms < 0 {
      0
    } else {
      initial_delay_ms
    },
    max_delay_ms: if max_delay_ms < 0 {
      0
    } else {
      max_delay_ms
    },
    backoff_factor: if backoff_factor < 1.0 {
      1.0
    } else {
      backoff_factor
    },
  }
}

///|
/// The delay to wait before attempt `attempt` (0-based) of the backoff
/// sequence, capped at `max_delay_ms`.
pub fn RetryPolicy::delay_ms(self : RetryPolicy, attempt : Int32) -> Int32 {
  let mut delay = self.initial_delay_ms.to_double()
  let mut index = 0
  while index < attempt {
    delay = delay * self.backoff_factor
    index = index + 1
  }
  let capped = if delay > self.max_delay_ms.to_double() {
    self.max_delay_ms.to_double()
  } else {
    delay
  }
  capped.to_int()
}

///|
/// A transport that re-sends requests the server answered with 429 or 5xx.
///
/// It waits between attempts only on the caller's behalf: the library never
/// sleeps, because blocking inside a transport is exactly the implicit
/// behaviour the retry policy is meant to avoid. Instead each retry is
/// announced as `on_retry(attempt, delay_ms, error)` and the delay is
/// stamped on the request as `x-chroma-retry-delay-ms`, the same contract
/// `TimeoutTransport` uses for deadlines. A transport that cannot wait and
/// has no hook still sees the retried requests; it just sends them back to
/// back.
pub(all) struct RetryTransport[T] {
  inner : T
  policy : RetryPolicy
  on_retry : ((Int32, Int32, ChromaError) -> Unit)?
}

///|
/// The header carrying the delay a real transport should wait before
/// re-sending.
pub const RETRY_DELAY_HEADER : String = "x-chroma-retry-delay-ms"

///|
/// Wraps `inner` with `policy`.
pub fn[T] RetryTransport::new(
  inner : T,
  policy~ : RetryPolicy = RetryPolicy::new(),
) -> RetryTransport[T] {
  { inner, policy, on_retry: None, }
}

///|
/// Returns a copy that reports every retry before it is attempted.
///
/// The callback is where a real transport blocks, logs or reports metrics;
/// a browser build could sleep with `setTimeout` there.
pub fn[T] RetryTransport::on_retry(
  self : RetryTransport[T],
  handler : (Int32, Int32, ChromaError) -> Unit,
) -> RetryTransport[T] {
  { ..self, on_retry: Some(handler), }
}

///|
/// Returns a copy with a different policy.
pub fn[T] RetryTransport::with_policy(
  self : RetryTransport[T],
  policy : RetryPolicy,
) -> RetryTransport[T] {
  { ..self, policy, }
}

///|
/// Sends the request, retrying while the server reports a transient
/// failure and attempts remain.
pub impl[T : Transport] Transport for RetryTransport[T] with fn send(
  self,
  request,
) {
  if !self.policy.enabled {
    return self.inner.send(request)
  }
  let mut attempt = 0
  let mut last : Response? = None
  while attempt < self.policy.max_attempts {
    let response = self.inner.send(request)
    // `last` keeps the final response so the loop can report it on the
    // last attempt without duplicating the error-building code.
    last = Some(response)
    if !is_transient(response) {
      return response
    }
    attempt = attempt + 1
    if attempt >= self.policy.max_attempts {
      break
    }
    let delay = self.policy.delay_ms(attempt - 1)
    match self.on_retry {
      Some(handler) =>
        handler(attempt, delay, api_error(response.status, response.body))
      None => ()
    }
    // The header is recomputed per attempt rather than accumulated, so a
    // transport always sees the delay of the retry it is about to make.
    request.headers[RETRY_DELAY_HEADER] = delay.to_string()
  }
  match last {
    Some(response) => raise api_error(response.status, response.body)
    // `max_attempts` is clamped to at least 1, so the loop always runs.
    None => abort("retry loop never ran")
  }
}

///|
/// Whether a response is worth re-sending: the server was reachable but
/// asked the client to come back (429), or failed on its side (5xx).
fn is_transient(response : Response) -> Bool {
  response.status == 429 || (response.status >= 500 && response.status < 600)
}

///|
/// Errors raised by `ChromaClient::send` keep their original shape, so the
/// retry loop only has to decide on HTTP statuses. A failure to send at all
/// is not retried: under a transport that raises instead of returning a
/// status there is no way to tell a dropped connection from a bad URL.
pub fn[T] RetryTransport::policy(self : RetryTransport[T]) -> RetryPolicy {
  self.policy
}

///|
pub extend RetryPolicy with Eq::{not_equal, equal}

///|
pub extend RetryPolicy with @debug.Debug::{to_repr}

///|
pub extend RetryTransport with Transport::{send}
