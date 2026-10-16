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

## Errors

Every fallible call raises `ChromaError`:

- `Transport(String)` — the request could not be sent;
- `Status(Int, String)` — the server answered non-2xx;
- `Decode(String)` — the response body was not the expected JSON.

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
implemented; authentication-specific headers are passed through
`Config::headers`, and tenant/database selection is part of the config.

## License

Apache-2.0.
