///|
/// Tests for the asynchronous half of the client.
///
/// The `_async` methods duplicate the synchronous request-building code (see
/// the note at the top of `async.mbt`), so the point of these tests is not to
/// re-prove the wire format — `client_test.mbt` does that once — but to prove
/// the two halves stay in step: same path, same verb, same body, same error
/// mapping. `ScriptedAsyncTransport` replays responses without a server, the
/// way `MemoryTransport` does for the synchronous methods.
///
/// `chroma_wbtest.mbt` covers the same methods against a real Chroma server
/// when `CHROMA_ENDPOINT` is set; these tests are what runs everywhere else.

///|
async test "heartbeat_async reads the nanosecond envelope" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"nanosecond heartbeat\": 42}"),
  ])
  let client = ChromaClient::new(transport)
  assert_eq(client.heartbeat_async(), 42)
  let request = transport.last_request().unwrap()
  assert_eq(request.url, "http://localhost:8000/api/v2/heartbeat")
}

///|
async test "version_async reads the version string and tolerates a non-string" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "\"1.0.0\""),
    Response::json(200, "{\"version\": \"1.0.0\"}"),
  ])
  let client = ChromaClient::new(transport)
  assert_eq(client.version_async(), "1.0.0")
  // A server that answers with an object loses the version but must not fail
  // the call: the point is reachability, and the shape is not guaranteed.
  assert_eq(client.version_async(), "")
}

///|
async test "list_collections_async builds a v2 request and decodes the array" {
  let payload = "[{\"id\":\"c1\",\"name\":\"notes\"},{\"id\":\"c2\",\"name\":\"docs\"}]"
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, payload),
  ])
  let client = ChromaClient::new(transport)
  let collections = client.list_collections_async()
  assert_eq(collections.length(), 2)
  assert_eq(collections[1].name, "docs")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, Get)
  assert_eq(
    request.url,
    "http://localhost:8000/api/v2/tenants/default_tenant/databases/default_database/collections",
  )
}

///|
async test "list_collections_async rejects a non-array response" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"count\": 0}"),
  ])
  let client = ChromaClient::new(transport)
  let result = try_async(() => ignore(client.list_collections_async()))
  assert_true(result is Err(Decode(_)))
}

///|
async test "count_collections_async reads a bare integer" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "4"),
  ])
  let client = ChromaClient::new(transport)
  assert_eq(client.count_collections_async(), 4)
}

///|
async test "create_collection_async sends get_or_create false" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"id\":\"c3\",\"name\":\"wiki\"}"),
  ])
  let client = ChromaClient::new(transport)
  let collection = client.create_collection_async("wiki")
  assert_eq(collection.id, "c3")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, Post)
  assert_true(request.body.unwrap().contains("\"get_or_create\":false"))
}

///|
async test "get_or_create_collection_async sends get_or_create true" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"id\":\"c3\",\"name\":\"wiki\"}"),
  ])
  let client = ChromaClient::new(transport)
  ignore(client.get_or_create_collection_async("wiki"))
  let request = transport.last_request().unwrap()
  assert_true(request.body.unwrap().contains("\"get_or_create\":true"))
}

///|
async test "get_collection_async returns None on 404 and re-raises the rest" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(404, "{\"error\":\"NotFound\"}"),
    Response::json(500, "{\"error\":\"InternalError\"}"),
  ])
  let client = ChromaClient::new(transport)
  assert_true(client.get_collection_async("missing") is None)
  let result = try_async(() => ignore(client.get_collection_async("boom")))
  match result {
    Err(Api(error)) => assert_eq(error.status, 500)
    _ => fail("expected the 500 to surface as an Api error")
  }
}

///|
async test "get_collection_async percent-encodes the name" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"id\":\"c1\",\"name\":\"my notes\"}"),
  ])
  let client = ChromaClient::new(transport)
  ignore(client.get_collection_async("my notes"))
  let request = transport.last_request().unwrap()
  assert_true(request.url.has_suffix("/collections/my%20notes"))
}

///|
async test "delete_collection_async builds a DELETE without a body" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.delete_collection_async("wiki")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, Delete)
  assert_true(request.body is None)
}

///|
async test "count_async reads the collection record count" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "7"),
  ])
  let client = ChromaClient::new(transport)
  assert_eq(client.count_async("c1"), 7)
  assert_true(
    transport.last_request().unwrap().url.has_suffix("/collections/c1/count"),
  )
}

///|
async test "add_async sends columnar records and validates locally" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.add_async("c1", [Record::of_embedding("a", [1.0, 0.0])])
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"ids\":[\"a\"]"))
  // An empty batch is refused before a request is built.
  let result = try_async(() => client.add_async("c1", []))
  assert_true(result is Err(InvalidArgument(_)))
}

///|
async test "upsert_async sends the upsert path" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.upsert_async("c1", [Record::of_embedding("a", [1.0])])
  assert_true(
    transport.last_request().unwrap().url.has_suffix("/collections/c1/upsert"),
  )
}

///|
async test "update_async patches only what it is given" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.update_async(
    "c1",
    [
      {
        id: "a",
        document: None,
        embedding: None,
        metadata: [("topic", MString("after"))],
      },
    ],
    filter=Filter::new().with_metadata("topic", MString("before")),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  // A missing embedding is the normal case for an update, so it must be a
  // null column rather than a validation failure.
  assert_true(body.contains("\"embeddings\":[null]"))
  assert_true(body.contains("\"where\""))
}

///|
async test "delete_async sends ids and where clauses" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.delete_async(
    "c1",
    filter=Filter::new(
      where_document_clause=Some(@json.parse("{\"$contains\":\"x\"}")),
      ids=["a", "b"],
    ),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"ids\":[\"a\",\"b\"]"))
  assert_true(body.contains("where_document"))
}

///|
async test "get_async posts the filter and decodes the result" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"ids\":[\"a\"],\"documents\":[\"hello\"]}"),
  ])
  let client = ChromaClient::new(transport)
  let result = client.get_async("c1", filter=Filter::new().with_limit(10))
  assert_eq(result.ids, ["a"])
  assert_eq(result.documents, [Some("hello")])
}

///|
async test "query_embeddings_async sends vectors and validates inputs" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"ids\":[[\"a\"]],\"distances\":[[0.5]]}"),
  ])
  let client = ChromaClient::new(transport)
  let result = client.query_embeddings_async("c1", [[1.0, 0.0]], n_results=1)
  assert_eq(result.ids, ["a"])
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"query_embeddings\":[[1,0]]"))
  assert_true(body.contains("\"n_results\":1"))
  // Empty inputs and a non-positive n_results are local mistakes.
  assert_true(
    try_async(() => ignore(client.query_embeddings_async("c1", [])))
    is Err(InvalidArgument(_)),
  )
  assert_true(
    try_async(() => {
      ignore(client.query_embeddings_async("c1", [[1.0]], n_results=0))
    })
    is Err(InvalidArgument(_)),
  )
}

///|
async test "peek_async clamps the limit and posts to get" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{\"ids\":[\"a\"]}"),
    Response::json(200, "{\"ids\":[]}"),
  ])
  let client = ChromaClient::new(transport)
  ignore(client.peek_async("c1", limit=5000))
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"limit\":100"))
  // A limit below 1 is clamped up rather than sent as-is.
  ignore(client.peek_async("c1", limit=0))
  assert_true(
    transport.last_request().unwrap().body.unwrap().contains("\"limit\":1"),
  )
}

///|
async test "modify_collection_async sends new_name and new_metadata" {
  let transport = ScriptedAsyncTransport::new(responses=[
    // Resolving the name to an id costs one extra `GET`.
    Response::json(
      200, "{\"id\":\"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\",\"name\":\"wiki\"}",
    ),
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.modify_collection_async(
    "wiki",
    new_name=Some("docs"),
    metadata=Some([("topic", MString("ai"))]),
  )
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, Put)
  assert_true(
    request.url.has_suffix("/collections/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
  )
  let body = request.body.unwrap()
  assert_true(body.contains("\"new_name\":\"docs\""))
  assert_true(body.contains("\"new_metadata\""))
}

///|
async test "modify_collection_async sends an empty body when given nothing" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(
      200, "{\"id\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"name\":\"wiki\"}",
    ),
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.modify_collection_async("wiki")
  assert_eq(transport.last_request().unwrap().body.unwrap(), "{}")
}

///|
async test "modify_collection_async uses an id as-is without a lookup" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.modify_collection_async("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
  assert_eq(transport.observed().length(), 1)
  assert_true(
    transport.last_request().unwrap().url.has_suffix(
      "/collections/dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    ),
  )
}

///|
async test "an async transport's parsed error is not flattened" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(503, "{\"error\":\"Unavailable\"}"),
  ])
  let client = ChromaClient::new(transport)
  let result = try_async(() => ignore(client.heartbeat_async()))
  match result {
    Err(Api(error)) => {
      assert_eq(error.status, 503)
      assert_eq(error.error_code, "Unavailable")
    }
    _ => fail("expected the 503 to surface as an Api error")
  }
}

///|
async test "async headers reach every request" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "42"),
  ])
  let client = ChromaClient::new(
    transport,
    config=Config::new().with_token("secret").with_header("x-trace", "abc"),
  )
  ignore(client.heartbeat_async())
  let headers = transport.last_request().unwrap().headers
  assert_eq(headers.get("authorization"), Some("Bearer secret"))
  assert_eq(headers.get("x-trace"), Some("abc"))
  // The transport is responsible for content-type; the client always sets it.
  assert_eq(headers.get("content-type"), Some("application/json"))
}

///|
async test "an async transport failure becomes a Transport error" {
  let transport = FailingAsyncTransport::new(
    error=ChromaError::Transport("connection refused"),
  )
  let client = ChromaClient::new(transport)
  let result = try_async(() => ignore(client.heartbeat_async()))
  match result {
    Err(Transport(message)) => assert_eq(message, "connection refused")
    _ => fail("expected the transport failure to surface as Transport")
  }
}

///|
async test "an inner transport's classified error is re-raised unchanged" {
  // The client's contract is that a `Status`/`Api`/`Decode` error an inner
  // transport produced keeps its shape, so a caller still sees the status.
  let transport = FailingAsyncTransport::new(
    error=ChromaError::Status(503, "gateway"),
  )
  let client = ChromaClient::new(transport)
  let result = try_async(() => ignore(client.heartbeat_async()))
  assert_true(result is Err(Status(503, _)))
}

///|
async test "update_async and delete_async forward every filter clause" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
    Response::json(200, "{}"),
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  let filter = Filter::new(
    where_clause=Some(@json.parse("{\"topic\":\"ai\"}")),
    where_document_clause=Some(@json.parse("{\"$contains\":\"moon\"}")),
    ids=["a"],
  )
  client.update_async("c1", [Record::of_embedding("a", [1.0])], filter~)
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"where\""))
  assert_true(body.contains("where_document"))
  client.delete_async("c1", filter~)
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"where\""))
  assert_true(body.contains("where_document"))
  assert_true(body.contains("\"ids\":[\"a\"]"))
  // With no filter there is nothing to patch by, so only the columns remain.
  client.update_async("c1", [Record::of_embedding("a", [1.0])])
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(!body.contains("\"where\""))
  assert_true(!body.contains("where_document"))
}

///|
async test "delete_async omits the ids column when the filter has none" {
  let transport = ScriptedAsyncTransport::new(responses=[
    Response::json(200, "{}"),
  ])
  let client = ChromaClient::new(transport)
  client.delete_async("c1")
  assert_eq(transport.last_request().unwrap().body.unwrap(), "{}")
}

///|
async test "a scripted response queue that runs dry answers an empty object" {
  // A test that asserts on the request a client built still needs a response
  // for the call to return; an empty object is the neutral value.
  let transport = ScriptedAsyncTransport::new()
  let client = ChromaClient::new(transport)
  client.delete_collection_async("docs")
  assert_eq(transport.observed().length(), 1)
  assert_true(!(transport.last_request() is None))
}

///|
async test "an async error an inner transport decoded is re-raised" {
  let transport = FailingAsyncTransport::new(
    error=ChromaError::Decode("bad shape"),
  )
  let client = ChromaClient::new(transport)
  let result = try_async(() => ignore(client.heartbeat_async()))
  assert_true(result is Err(Decode(_)))
}
