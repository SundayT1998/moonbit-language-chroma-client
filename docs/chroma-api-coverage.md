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

| Chroma endpoint | Why not |
| --- | --- |
| `POST /query` with `query_texts` | Chroma 1.x has **no server-side embedding**; the server rejects documents it would have to embed (422), so a `query_text` method could never succeed. Vectors come from your own embedding model — see `Record::with_embedding`. |
| `GET /version` | Not needed by the client; a caller who wants it can build the request with the exported `Request` / `Transport` types. |
| Tenant endpoints (`GET`/`POST /tenants`) | Multi-tenant administration is out of scope; tenant and database are config, not client operations. |
| `POST /collections/{id}/fork`, `/reset`, and other newer endpoints | Not implemented. They arrive with newer Chroma releases and are tracked as they stabilise. |
| `GET /collections/{id}/preflight` | Not implemented; request validation is done locally instead (`validate_records` and friends). |

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
backed by tests. `chroma_wbtest.mbt` exercises every covered endpoint above
against a real server when `CHROMA_ENDPOINT` is set:

```bash
sh scripts/integration.sh
```

To see what the client actually sends, point a `MemoryTransport` at
`ChromaClient` and inspect the recorded `Request` — `client_test.mbt` is full
of examples.
