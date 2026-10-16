# SundayT1998/chroma-client

A [Chroma](https://www.trychroma.com/) vector-database client for MoonBit.

Chroma is the embedding database commonly used behind retrieval-augmented
generation (RAG) pipelines. `chroma-client` speaks Chroma's **v2 HTTP API**
so MoonBit programs can create collections, add and query documents, and
manage records without leaving the language.

## Docs

The README is the entry point; everything longer lives in [`docs/`](docs/):

- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — setup, the checks a change
  has to pass, the two test layers, code style, commit and PR conventions.
- [`docs/chroma-api-coverage.md`](docs/chroma-api-coverage.md) — which Chroma
  v2 endpoints the client covers, which it deliberately does not, and why.

## Design

The library builds requests and decodes responses, and delegates the actual
sockets to a trait. It ships the transport real applications use —
`AsyncHttpTransport`, backed by `moonbitlang/async/http` — and leaves the trait
open so an application with its own HTTP stack can plug it in. There are two
traits:

- `AsyncTransport` — asynchronous, with `async fn send_async`. This is the one
  the bundled `AsyncHttpTransport` implements, because
  `moonbitlang/async/http` only offers `async` functions and an `async` call
  cannot be made from a synchronous one.

- `Transport` — synchronous. `MemoryTransport` implements it, so scripted
  responses cover the whole request/response cycle in ordinary `moon test`
  runs.

Every public method exists in both flavours: `client.add(...)` is synchronous,
`client.add_async(...)` is asynchronous. Choosing between them is choosing
which trait your transport implements and whether your call site is `async`.

The library ships its own transport, `AsyncHttpTransport`, backed by
`moonbitlang/async/http`: a Chroma client that cannot reach a server is not
useful, and native + wasm both run on the async stack the ecosystem already
has. Callers get a working client out of the box, and the transport is:

- **portable** — the same code runs on `native`, `wasm` and `js`. The
  transport limits the library to the backends `moonbitlang/async` supports;
  `wasm-gc` has no async runtime yet, so it is not a supported target;
- **testable** — `MemoryTransport` implements the synchronous `Transport` and
  replays scripted responses, so the whole request/response cycle is covered by
  ordinary `moon test` runs without a server;
- **replaceable** — `AsyncTransport` is a two-method-wide seam, so an
  application that already owns an HTTP stack can plug it in instead of using
  the bundled one.

## Install

```bash
moon add SundayT1998/chroma-client
```

## Quick start

```moonbit nocheck
///|
async fn example() -> Unit raise @chroma.ChromaError {
  // `AsyncHttpTransport` is bundled; point the config at your Chroma server.
  let client = @chroma.ChromaClient::new(
    @chroma.AsyncHttpTransport::new(),
    config=@chroma.Config::new(endpoint="http://localhost:8000"),
  )

  let collection = client.get_or_create_collection_async("notes")

  // Chroma 1.x stores vectors, not text: every record needs coordinates.
  client.add_async(collection.id, [
    @chroma.Record::of_embedding("r1", [1.0, 0.0, 0.0]).with_document(
      "MoonBit is a language for the web",
    ),
    @chroma.Record::of_embedding("r2", [0.0, 1.0, 0.0]).with_document(
      "Chroma stores embeddings",
    ),
  ])

  let result = client.query_embeddings_async(
    collection.id,
    [[1.0, 0.0, 0.0]],
    n_results=2,
  )
  for id in result.ids {
    println(id)
  }
}
```

`AsyncHttpTransport` ships with the library (see [Native transport](#native-transport)),
so most callers never write a transport. If your application already owns an
HTTP stack, implement `@chroma.AsyncTransport` instead — see
[Adding a real transport](#adding-a-real-transport).

> **Chroma 1.x has no server-side embedding.** An `add` whose records carry
> documents but no vectors is rejected by the server, so the client refuses it
> locally and points at `Record::with_embedding`. Produce the vectors with
> whatever embedding model you already use; `Record::of_document(...).with_embedding(vec)`
> is the usual shape.

## Choosing what a query returns

`QueryResult` mirrors Chroma's `include` field:

```moonbit nocheck
client.query_embeddings_async(
  collection.id,
  [[0.1, 0.9, 0.0]],
  n_results=5,
  include_fields=@chroma.Include::all(),
)
```

`Include::default()` returns documents, metadata and distances;
`Include::ids_only()` returns just ids.

## Filtering

`Filter` builds Chroma's `where` / `where_document` clauses:

```moonbit nocheck
let filter = @chroma.Filter::new()
  .with_metadata("source", @chroma.MString("handbook"))
  .with_limit(20)
client.get_async(collection.id, filter=filter)
```

## Metadata types

Chroma accepts only scalar metadata. `MetadataValue` models that directly:

```moonbit nocheck
@chroma.MetadataValue::MString("hello")
@chroma.MetadataValue::MInt(42)
@chroma.MetadataValue::MFloat(0.5)
@chroma.MetadataValue::MBool(true)
@chroma.MetadataValue::MNull
```

Collections and records take a `Metadata` value, which is an ordered list of
`(key, MetadataValue)` pairs.

## Adding a real transport

Implement `@chroma.AsyncTransport` against whatever HTTP stack you use. With
`moonbitlang/async/http`, the whole transport is a dozen lines:

```moonbit nocheck
///|
impl @chroma.AsyncTransport for MyTransport with fn send_async(self, request) {
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
  {
    status: response.code,
    headers: converted(response.headers),
    body: response_body.text(),
  }
}
```

`Request` carries the verb, URL, headers and optional JSON body; the transport
only has to return a `Response`.

That is exactly what the bundled `AsyncHttpTransport` does; its source is
`async_http_transport.mbt`. With `moonbitlang/async/http` the `impl` alone is
not enough: MoonBit also needs an `extend` declaration to make the method
callable:

```moonbit night
///|
pub extend MyTransport with @chroma.AsyncTransport::{send_async}
```

## Native transport

`AsyncHttpTransport` (in the library) is wired to `moonbitlang/async/http`,
which is the only HTTP client in the ecosystem that runs on `native`:

```bash
moon run cmd/main --target native -- http://localhost:8000 my-collection
```

It creates a collection, adds vectors, counts, queries with distances, applies
a metadata filter, and deletes the collection — a full round-trip against a
real server, and the fastest way to check that a local Chroma is reachable.

For a long-lived application, hold one `@ah.Client` open and reuse it rather
than connecting per request: `@ah.Client` keeps the connection alive, while
the example's `@ah.request` helper does not.

## Authentication

`Config` carries the headers every request shares. The common schemes have
shorthands so they do not have to be spelled out by hand:

```moonbit nocheck
///|
let client = @chroma.ChromaClient::new(
  transport,
  config=@chroma.Config::new()
    .with_token("my-api-token")
    .with_basic_auth("user", "password"),
)
```

`with_headers` merges a whole map, and `with_header` sets a single value.
All four return a copy, so the original configuration is never mutated.

## Timeouts

The library performs no I/O, so it cannot cancel a socket read by itself.
`TimeoutTransport` makes the deadline explicit instead: it stamps
`x-chroma-timeout-ms` on every request, and the real transport is expected to
honour it.

```moonbit nocheck
///|
let client = @chroma.ChromaClient::new(
  @chroma.TimeoutTransport::new(http_stack, 5000),
  // or, to pick up Config::timeout_ms:
  // @chroma.TimeoutTransport::from_config(http_stack, config)
)
```

A `timeout_ms` of `0` or less disables the wrapper and passes requests
through untouched.

## Counting and previewing

```moonbit nocheck
///|
let total = client.count(collection.id)

///|
let sample = client.peek(collection.id, limit=5)
```

`peek` is `get` with a limit, but the limit is clamped to
`PEEK_LIMIT` (100) so a preview can never turn into a full scan.

## Pagination

`Filter` carries `limit` and `offset`, and Chroma requires `offset` to be
smaller than `limit` — it walks a page, it does not skip past the end of
one. Violating that raises `InvalidArgument` locally instead of costing a
round-trip and an opaque 400:

```moonbit nocheck
///|
client.get_async(
  collection.id,
  filter=@chroma.Filter::new(limit=Some(10), offset=Some(5)),
)
```

`query_embeddings` accepts `n_results` and rejects values `<= 0` the same way.
On a query Chroma only honours `where` / `where_document`, so `limit`, `offset`
and `ids` are dropped rather than forwarded.

## Records and vectors

Chroma stores a vector for every record; the document, when present, is the
text that vector stands for. The client models that directly:

```moonbit nocheck
///|
// Vector first, text attached afterwards.
@chroma.Record::of_embedding("r1", [1.0, 0.0]).with_document("hello")

///|
// Text first, vector attached afterwards.
@chroma.Record::of_document("r2", "world").with_embedding([0.0, 1.0])

///|
// Metadata, either way.
@chroma.Record::of_embedding("r3", [1.0, 1.0]).with_metadata([
  ("source", @chroma.MString("handbook")),
])
```

`add` and `upsert` require the vector; `update` does not, because an update
patches a record by id and a missing field means "leave this one alone". A
batch that `add` would have to reject is refused before a request is built, so
the failure names the record instead of arriving as a server-side 422.

## Errors

Every fallible call raises `ChromaError`:

- `Transport(String)` — the request could not be sent;
- `Api(ApiError)` — the server answered non-2xx with Chroma's error body;
- `Status(Int, String)` — the server answered non-2xx with a body that is not
  a Chroma error envelope (a proxy page, say);
- `Decode(String)` — the response body was not the expected JSON;
- `InvalidArgument(String)` — the arguments would be rejected by Chroma, so
  nothing was sent.

`ApiError` splits the response so no caller has to parse it again: `status`,
`error_code` (Chroma's short label), `message` (the sentence), `details` (any
extra structure) and the raw `body`. A couple of helpers cover the usual
branches:

```moonbit nocheck
///|
match result {
  Err(error) =>
    if error.status_code() == Some(404) {
      // nothing there
    } else if error.is_retryable() {
      // 429 or 5xx, worth trying again
    } else {
      println(error.message())
    }
  Ok(value) => ignore(value)
}
```

## Retrying

Retrying is opt-in: a plain client sends one request and reports what came
back. Wrapping the transport with a `RetryPolicy` turns on retries for 429 and
5xx only — a 4xx is a deterministic answer, so repeating it just burns a
round-trip.

```moonbit nocheck
///|
let client = @chroma.ChromaClient::new(
  @chroma.RetryTransport::new(
    http_stack,
    policy=@chroma.RetryPolicy::new(
      enabled=true,
      max_attempts=3,
      initial_delay_ms=200,
      max_delay_ms=5000,
      backoff_factor=2.0,
    ),
  ),
)
```

The library still performs no I/O, so it never sleeps. Each retry is announced
through `on_retry(attempt, delay_ms, error)`, and the delay is stamped on the
request as `x-chroma-retry-delay-ms` for a transport that can wait:

```moonbit nocheck
///|
let transport = @chroma.RetryTransport::new(http_stack).on_retry((
  attempt,
  delay_ms,
  error,
) => {
  println(
    "retry " +
    attempt.to_string() +
    " in " +
    delay_ms.to_string() +
    "ms: " +
    error.to_string(),
  )
})
```

For example, in a `js` transport the callback is where `setTimeout` belongs.

## Response size

A response body is read into one `String`, so the client caps it at
`MAX_RESPONSE_BYTES` (32 MiB) and raises `Decode` past it. Truncating would
turn a memory problem into silent data loss, so the client fails loudly
instead; the fix on the caller's side is to narrow `include`, lower
`n_results`, or page with `limit`. Error bodies are read before the cap is
applied, so a long error message still reaches the caller.

## Local validation

Arguments Chroma would reject outright are caught before a request is built,
so a bug in your code surfaces as a `InvalidArgument` with a sentence rather
than a 400 and a round-trip:

- an empty `records` batch on `add` / `upsert` / `update`;
- a record with an empty `id`, or with neither a `document` nor an
  `embedding`;
- an empty `embeddings` list on `query_embeddings`;
- `n_results <= 0`, and an `offset` that is not smaller than `limit`.

The checks are exposed as `validate_records`, `validate_query_inputs`,
`validate_n_results` and `validate_limit_offset` if you build requests
yourself.

## Decoding rules

The client distinguishes fields Chroma always returns from fields that depend
on the request:

- required and missing ⇒ `Decode`. `Collection.id` / `Collection.name` and the
  `ids` of a `get` result are never silently defaulted, because an empty list
  and a broken response are different answers;
- optional and missing ⇒ empty default. `metadata`, `configuration`,
  `log_position`, `version`, and everything `include` controls (`documents`,
  `embeddings`, `metadatas`, `distances`) may legitimately be absent.

## Examples

`cmd/main` is a single runnable example: it talks to a real Chroma server
through the library's `AsyncHttpTransport` — see
[Native transport](#native-transport) above.

```bash
moon run cmd/main --target native -- http://localhost:8000 my-collection
```

## Testing

Two layers, both run by CI. [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md)
has the full version, including when a change needs a live test.

The unit suite uses `MemoryTransport` and needs nothing but `moon`:

```bash
sh scripts/ci.sh
```

It runs, in order: formatting, `moon check`, generated-interface freshness,
tests with coverage, coverage reports, and debug + release builds. A single
step can be run on its own:

```bash
sh scripts/ci.sh fmt check     # just formatting and type-checking
sh scripts/ci.sh test coverage # just tests and coverage
```

The live suite (`chroma_wbtest.mbt`) runs against a real Chroma server and is
what caught the protocol bugs the unit tests could not: scripted responses only
prove the client agrees with itself. It shares the root package with the
client, and the transport it drives
(`AsyncHttpTransport`, backed by `moonbitlang/async/http`) is exported by the
library, so the code under test is exactly what an application runs.
Those tests skip when `CHROMA_ENDPOINT` is unset, so `scripts/ci.sh` stays
runnable without Docker. To run them, start a server and point the suite at it:

```bash
sh scripts/integration.sh      # starts chromadb/chroma, runs, tears down
```

or, against a server you already have:

```bash
CHROMA_ENDPOINT=http://localhost:8000 \
  moon test --target native -p SundayT1998/chroma-client
```

Both CI platforms run them: CNB starts the container through the `docker`
service in `.cnb.yml`, and GitHub Actions uses a `services:` container on
`ubuntu-latest` only, since the service container does not exist on macOS or
Windows.

Set `CHROMA_TEST_RUN_ID` when several jobs share one server: each run
namespaces its collection names with it, so parallel runs cannot collide.

## Status

Early but functional, and verified against a live server rather than only
against scripted responses. The v2 collection, record and query endpoints are
implemented, including `count` and `peek`; token and basic authentication have
shorthands on `Config`, and tenant/database selection is part of the config.
Server errors are parsed into `ApiError`, transient failures can be retried
explicitly, and request arguments are validated locally before they are sent.

Both a synchronous and an asynchronous API exist, and the wire format matches
Chroma 1.x: columnar record bodies, `get_or_create`, bare-integer counts, and
no text-to-vector conversion on the server.

## License

Apache-2.0.
