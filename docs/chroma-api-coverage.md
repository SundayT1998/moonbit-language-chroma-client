# Chroma API coverage

The client speaks Chroma's **v2 HTTP API**, rooted at
`{endpoint}/api/v2/tenants/{tenant}/databases/{database}/`. This page lists,
endpoint by endpoint, what the client covers and what it deliberately does not.

Every method below exists in two flavours: `client.add(...)` is synchronous
(`Transport`), `client.add_async(...)` is asynchronous (`AsyncTransport`).
They are the same call over the same path, so the table lists them once.

## Covered

| Chroma endpoint | Client method(s) |
| --- | --- |
| `GET /heartbeat` | `heartbeat`, `heartbeat_async` |
| `GET /version` | `version`, `version_async` |
| `GET /collections` | `list_collections`, `list_collections_async` |
| `POST /collections` | `create_collection`, `get_or_create_collection` (+ `_async`) |
| `GET /collections/{id}` | `get_collection`, `get_collection_async` |
| `DELETE /collections/{id}` | `delete_collection`, `delete_collection_async` |
| `PUT /collections/{id}` | `modify_collection`, `modify_collection_async` |
| `GET /collections_count` | `count_collections`, `count_collections_async` |
| `GET /collections/{id}/count` | `count`, `count_async` |
| `GET /collections/{id}/get` | `get`, `get_async`, and `peek` (limit clamped to 100) |
| `POST /collections/{id}/add` | `add`, `add_async` |
| `POST /collections/{id}/update` | `update`, `update_async` |
| `POST /collections/{id}/upsert` | `upsert`, `upsert_async` |
| `POST /collections/{id}/delete` | `delete`, `delete_async` |
| `POST /collections/{id}/query` | `query_embeddings`, `query_embeddings_async` |

Body shapes matter here, and they are not what the older 0.x API used:

- records are sent **columnar** (`ids` / `embeddings` / `documents` /
  `metadatas` as parallel arrays, missing values padded with `null`), matching
  Chroma's `AddEmbedding` model;
- `create_collection` always sends `get_or_create`, so the two entry points
  differ by that flag rather than by path;
- `count` and `collections_count` decode a **bare integer**; a `{"count": n}`
  envelope is accepted too;
- `heartbeat` returns `{"nanosecond heartbeat": <int>}` and is surfaced as an
  `Int64`;
- `modify_collection` sends `new_metadata`, not `metadata`.

## Not covered

The entries below are deliberate gaps, not oversights: each one is either
impossible to call correctly from this client or outside what a client for the
data plane should do. "Not implemented" entries are candidates for a follow-up
once the endpoint's wire shape settles; "out of scope" entries are not.

| Chroma endpoint | Why not |
| --- | --- |
| `POST /query` with `query_texts` | Chroma 1.x has **no server-side embedding**; the server rejects documents it would have to embed (422), so a `query_text` method could never succeed. Vectors come from your own embedding model — see `Record::with_embedding`. |
| Tenant endpoints (`GET`/`POST /tenants`) | Multi-tenant administration is out of scope; tenant and database are config, not client operations. |
| `POST /collections/{id}/fork` | Not implemented yet. It arrives with newer Chroma releases and is tracked here until the request/response shape stabilises. |
| `POST /collections/{id}/reset` | Not implemented. It is destructive by design (it drops every record in a collection), so it would ship behind an explicitly named method rather than as the default way to empty a collection. |
| `GET /collections/{id}/preflight` | Not implemented. The server uses it to price a query before running it; the client validates the same arguments locally (`validate_records`, `validate_n_results`, `validate_limit_offset`) and lets the server reject anything it missed. |

## Handled outside the endpoint list

Some behaviour is not an endpoint but still has to be right:

- **Authentication** — `Config::with_token` (Bearer) and `Config::with_basic_auth`,
  plus `with_header` / `with_headers` for anything else. These are request
  headers, so they cover every endpoint.
- **Timeouts** — `timeout_ms` is stamped on requests as
  `x-chroma-timeout-ms` by `TimeoutTransport`; the client itself performs no
  I/O and cannot cancel a socket read.
- **Retries** — `RetryTransport` retries 429 and 5xx according to a
  `RetryPolicy`, announces each attempt through `on_retry`, and stamps the
  delay as `x-chroma-retry-delay-ms` for the transport to honour. A 4xx is
  never retried.
- **Errors** — non-2xx answers are decoded into `ApiError` (`status`,
  `error_code`, `message`, `details`, `body`); a body that is not a Chroma
  error envelope becomes `ChromaError::Status`.
- **Response size** — bodies are capped at `MAX_RESPONSE_BYTES` (32 MiB) and
  raise `Decode` past it, because truncating would turn a memory problem into
  silent data loss.
- **Local validation** — arguments Chroma would reject (`records` empty or
  without an embedding on `add`/`upsert`, `n_results <= 0`, `offset >= limit`)
  raise `InvalidArgument` before a request is built.

## Verifying coverage

Claiming an endpoint is implemented is only half the story; the claim is
backed by tests.

`client_test.mbt` drives every covered method through `MemoryTransport`, which
proves the request the client builds is the request the test expects. To see
what the client actually sends, point a `MemoryTransport` at `ChromaClient`
and inspect the recorded `Request`; that file is full of examples.

`chroma_wbtest.mbt` additionally talks to a real server when `CHROMA_ENDPOINT`
is set:

```bash
sh scripts/integration.sh
```

Its tests matter because scripted responses only prove the client agrees with
itself — the columnar record body, the bare integer the count endpoints return
and the `new_metadata` field on `modify_collection` were all found by a live
server, not by the unit suite.

Every covered method has a unit test, and the ones whose request shape the
server can silently reject — the columnar record body, the bare-integer count,
`new_metadata` on `modify_collection`, the `limit` on `peek` — also have a live
test. Add a live test when a change touches the wire format; a scripted
response cannot catch a field the server ignores.
