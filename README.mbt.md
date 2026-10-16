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
- `Status(Int, String)` — the server answered non-2xx;
- `Decode(String)` — the response body was not the expected JSON;
- `InvalidArgument(String)` — the arguments would be rejected by Chroma, so
  nothing was sent.

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

```bash
moon check --target all
moon test
```

## Status

Early but functional. The v2 collection, record and query endpoints are
implemented, including `count` and `peek`; token and basic authentication have
shorthands on `Config`, and tenant/database selection is part of the config.

## License

Apache-2.0.
