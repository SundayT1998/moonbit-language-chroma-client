# SundayT1998/chroma-client

A [Chroma](https://www.trychroma.com/) vector-database client for MoonBit.

Chroma is the embedding database commonly used behind retrieval-augmented
generation (RAG) pipelines. `chroma-client` speaks Chroma's **v2 HTTP API**
so MoonBit programs can create collections, add and query documents, and
manage records without leaving the language.

## Design

The library never performs socket I/O itself. Instead it builds requests and
decodes responses, and delegates the actual transport to a `Transport`
implementation you supply. That keeps the client:

- **portable** — the same code runs on `wasm`, `wasm-gc`, `js` and `native`;
- **testable** — `MemoryTransport` replays scripted responses, so the whole
  request/response cycle is covered by ordinary `moon test` runs;
- **embeddable** — you decide which HTTP stack, runtime and concurrency model
  your application already uses.

## Install

```bash
moon add SundayT1998/chroma-client
```

## Quick start

```moonbit nocheck
///|
fn example(transport : @chroma.Transport) -> Unit raise @chroma.ChromaError {
  let client = @chroma.ChromaClient::new(transport)

  let collection = client.get_or_create_collection("notes")

  client.add(collection.id, [
    @chroma.Record::of_document("r1", "MoonBit is a language for the web"),
    @chroma.Record::of_document("r2", "Chroma stores embeddings"),
  ])

  let result = client.query_text(
    collection.id,
    ["embedding database"],
    n_results=2,
  )
  for i, id in result.ids {
    println(id)
  }
}
```

Only documents are supplied, so Chroma embeds them server-side with its
default embedding function — the client needs no embedding model of its own.

## Choosing what a query returns

`QueryResult` mirrors Chroma's `include` field:

```moonbit nocheck
client.query_text(
  collection.id,
  ["vector search"],
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
client.get(collection.id, filter=filter)
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

Implement `@chroma.Transport` against whatever HTTP stack you use:

```moonbit nocheck
///|
struct MyTransport

///|
impl @chroma.Transport for MyTransport with fn send(self, request) {
  let response = my_http_stack_call(
    request.method,
    request.url,
    request.headers,
    request.body,
  )
  @chroma.json_response(response.status, response.body)
}
```

`Request` carries the verb, URL, headers and optional JSON body; the
transport only has to return a `Response`.

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
client.get(
  collection.id,
  filter=@chroma.Filter::new(limit=Some(10), offset=Some(5)),
)
```

`query_text` / `query_embeddings` accept `n_results`, and reject values `<= 0`
the same way. On a query Chroma only honours `where` / `where_document`, so
`limit`, `offset` and `ids` are dropped rather than forwarded.

## Working with alternative embedding functions

By default the server embeds documents and no embedding logic lives on the
client. When one collection mixes documents written with different functions, a
single record can pin its own:

```moonbit nocheck
///|
let record = @chroma.Record::of_document("r1", "hello").with_embedding_function(
  @json.parse("{\"name\": \"custom\"}"),
)
```

The override only makes sense with a `document`; a record that already carries
an `embedding` has nothing left to embed, so `with_embedding_function` raises
`InvalidArgument` rather than sending a request the server would reject.

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
- an empty `texts` list on `query_text`, or an empty `embeddings` list on
  `query_embeddings`;
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

```bash
moon run cmd/main -- my-collection
```

The example uses a logging transport, so it runs without a live server and
prints the exact requests the client would send.

## Testing

The same script runs locally, on GitHub Actions and on CNB:

```bash
sh scripts/ci.sh
```

It expects `moon` on `PATH` (GitHub installs it in the workflow, CNB ships it
in `.cnb/Dockerfile`) and then runs, in order: formatting, `moon check`,
generated-interface freshness, tests with coverage, coverage reports, and
debug + release builds.

A single step can be run on its own, which is handy while developing:

```bash
sh scripts/ci.sh fmt check     # just formatting and type-checking
sh scripts/ci.sh test coverage # just tests and coverage
```

## Status

Early but functional. The v2 collection, record and query endpoints are
implemented, including `count` and `peek`; token and basic authentication have
shorthands on `Config`, and tenant/database selection is part of the config.
Server errors are parsed into `ApiError`, transient failures can be retried
explicitly, and request arguments are validated locally before they are sent.

## License

Apache-2.0.
