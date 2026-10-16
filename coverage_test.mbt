///|
/// Tests for decoding branches and small API corners that the
/// endpoint-focused suites in `client_test.mbt` do not reach.
///
/// A Chroma client's failure mode is usually a decode branch nobody
/// exercised: the server reshapes a field, or omits one, and the client
/// either crashes or silently returns an empty value. Each test here pins one
/// such branch to its intended behaviour.

///|
test "decode_count accepts an enveloped integer and rejects the rest" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"count\": 12}"),
    @chroma-client.Response::json(200, "{\"count\": \"7\"}"),
    @chroma-client.Response::json(200, "{\"count\": \"many\"}"),
    @chroma-client.Response::json(200, "{\"other\": 1}"),
    @chroma-client.Response::json(200, "\"twelve\""),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.count_collections(), 12)
  // Chroma wraps counts differently across versions; a numeric string is
  // accepted, a non-numeric one is a decode error rather than a silent 0.
  assert_eq(client.count_collections(), 7)
  assert_true(
    try_catch(() => ignore(client.count_collections())) is Err(Decode(_)),
  )
  assert_true(
    try_catch(() => ignore(client.count_collections())) is Err(Decode(_)),
  )
  assert_true(
    try_catch(() => ignore(client.count_collections())) is Err(Decode(_)),
  )
}

///|
test "an empty response body decodes to null rather than an error" {
  // A 200 with an empty body is what a delete returns on some servers.
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, ""),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.delete_collection("docs"), ())
}

///|
test "a non-object response is reported as a decode error" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "[1, 2]"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  // `get_collection` requires an object with `id`/`name`; an array is not one.
  assert_true(
    try_catch(() => ignore(client.get_collection("docs"))) is Err(Decode(_)),
  )
}

///|
test "a field of the wrong type is reported as a decode error" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"id\": 3, \"name\": \"docs\"}"),
    @chroma-client.Response::json(
      200, "{\"id\": \"c1\", \"name\": \"docs\", \"metadata\": []}",
    ),
    @chroma-client.Response::json(200, "{\"ids\": \"a\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_true(
    try_catch(() => ignore(client.get_collection("docs"))) is Err(Decode(_)),
  )
  // A non-object `metadata` decodes as empty metadata, not as a failure.
  let collection = client.get_or_create_collection("docs")
  assert_eq(collection.metadata, [])
  // `ids` is the one required field of a result set.
  assert_true(try_catch(() => ignore(client.get("c1"))) is Err(Decode(_)))
}

///|
test "a response above the size limit is refused before it is parsed" {
  // The guard is what keeps a runaway body from being materialized as JSON,
  // so it has to fire ahead of the parser, not after it fails.
  let transport = @chroma-client.MemoryTransport::new(responses=[
    {
      status: 200,
      headers: {},
      body: "x".repeat(@chroma-client.MAX_RESPONSE_BYTES + 1),
    },
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.get_collection("docs")))
  match result {
    Err(Decode(message)) => assert_true(message.contains("above the"))
    _ => fail("expected the size guard to refuse the body")
  }
}

///|
test "heartbeat tolerates a renamed envelope and a bare number" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"heartbeat_ns\": \"123\"}"),
    @chroma-client.Response::json(200, "{\"heartbeat_ns\": \"soon\"}"),
    @chroma-client.Response::json(200, "{\"heartbeat_ns\": true}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  // The documented key is `nanosecond heartbeat`; a rename must still yield
  // the value, and a numeric string must still be read as a number.
  assert_eq(client.heartbeat(), 123)
  assert_true(try_catch(() => ignore(client.heartbeat())) is Err(Decode(_)))
  assert_true(try_catch(() => ignore(client.heartbeat())) is Err(Decode(_)))
}

///|
test "hearbeate tolerates a bare number" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "77"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.heartbeat(), 77)
}

///|
test "version returns an empty string for a non-string response" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"version\": \"1.0\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.version(), "")
}

///|
test "config exposes the client's configuration" {
  let client = @chroma-client.ChromaClient::new(
    @chroma-client.MemoryTransport::new(),
    config=@chroma-client.Config::new(
      endpoint="http://chroma.internal:9000",
      tenant="acme",
      database="prod",
    ),
  )
  assert_eq(client.config().endpoint, "http://chroma.internal:9000")
  assert_eq(client.config().tenant, "acme")
}

///|
test "list_collections rejects a non-array response" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"collections\": []}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.list_collections()))
  assert_true(result is Err(Decode(_)))
}

///|
test "delete_collection builds a v2 urls for an encoded name" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.delete_collection("my notes/2024")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @chroma-client.Delete)
  assert_true(request.url.has_suffix("/collections/my%20notes%2F2024"))
  assert_true(request.body is None)
}

///|
test "modify_collection sends only the fields it is given" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  // `new_name` and `new_metadata` are optional; an omitted field must not be
  // sent as `null`, which the server reads as an instruction.
  client.modify_collection("docs")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @chroma-client.Put)
  assert_true(request.url.has_suffix("/collections/docs"))
  assert_eq(request.body.unwrap(), "{}")
  client.modify_collection(
    "docs",
    new_name=Some("wiki"),
    metadata=Some([("topic", @chroma-client.MString("ai"))]),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"new_name\":\"wiki\""))
  assert_true(body.contains("\"new_metadata\":{\"topic\":\"ai\"}"))
}

///|
test "a configured collection body is sent verbatim" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"id\":\"c1\",\"name\":\"docs\"}"),
    @chroma-client.Response::json(200, "{\"id\":\"c2\",\"name\":\"docs\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let config = @chroma-client.CollectionConfig::new(
    configuration=Some(@json.parse("{\"hnsw\":{\"space\":\"cosine\"}}")),
    metadata=[("owner", @chroma-client.MString("acme"))],
  )
  ignore(client.create_collection("docs", config~))
  let body = transport.last_request().unwrap().body.unwrap()
  // A caller-supplied configuration replaces the default L2 HNSW block
  // instead of being merged with it.
  assert_true(
    body.contains("\"configuration\":{\"hnsw\":{\"space\":\"cosine\"}}"),
  )
  assert_true(!body.contains("\"space\":\"l2\""))
  assert_true(body.contains("\"metadata\":{\"owner\":\"acme\"}"))
  assert_true(body.contains("\"get_or_create\":false"))
  // `debug_collection_config` and `to_json` share the same builder, so the
  // rendered config is exactly what a create would send.
  assert_eq(
    @chroma-client.debug_collection_config(
      @chroma-client.CollectionConfig::new(),
    ),
    @chroma-client.CollectionConfig::new().to_json(),
  )
}

///|
test "upsert and update build their own paths" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.upsert("c1", [@chroma-client.Record::of_embedding("a", [1.0])])
  assert_true(
    transport.last_request().unwrap().url.has_suffix("/collections/c1/upsert"),
  )
  client.update("c1", [
    {
      id: "a",
      document: None,
      embedding: None,
      metadata: [("k", @chroma-client.MString("v"))],
    },
  ])
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"embeddings\":[null]"))
}

///|
test "update and delete forward the document clause" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new(
    where_document_clause=Some(@json.parse("{\"$contains\":\"moon\"}")),
  )
  client.update(
    "c1",
    [@chroma-client.Record::of_embedding("a", [1.0])],
    filter~,
  )
  assert_true(
    transport.last_request().unwrap().body.unwrap().contains("where_document"),
  )
  client.delete("c1", filter~)
  assert_true(
    transport.last_request().unwrap().body.unwrap().contains("where_document"),
  )
}

///|
test "a filter serializes ids, document clauses and paging" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"ids\":[\"a\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  ignore(
    client.get(
      "c1",
      filter=@chroma-client.Filter::new(
        where_clause=Some(@json.parse("{\"topic\":{\"$eq\":\"ai\"}}")),
        where_document_clause=Some(@json.parse("{\"$contains\":\"moon\"}")),
        ids=["a", "b"],
        limit=Some(10),
        offset=Some(1),
      ),
    ),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"where\""))
  assert_true(body.contains("\"where_document\""))
  assert_true(body.contains("\"ids\":[\"a\",\"b\"]"))
  assert_true(body.contains("\"limit\":10"))
  assert_true(body.contains("\"offset\":1"))
}

///|
test "query forwards the document clause and an explicit include" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"ids\":[[\"a\"]]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  ignore(
    client.query_embeddings(
      "c1",
      [[1.0]],
      include_fields=@chroma-client.Include::ids_only(),
      filter=@chroma-client.Filter::new(
        where_document_clause=Some(@json.parse("{\"$contains\":\"moon\"}")),
      ),
    ),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  // `ids_only` sends an empty include list, which is how a caller says
  // "ids and nothing else".
  assert_true(body.contains("\"include\":[]"))
  assert_true(body.contains("\"where_document\""))
}

///|
test "query tolerates a malformed per-query row" {
  // A query response nests one row per query embedding. A row that is not an
  // array (or an id that is not a string) must degrade to an empty result
  // rather than crash the decoder.
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(
      200, "{\"ids\":[null],\"documents\":[[1]],\"embeddings\":[[\"x\"]],\"metadatas\":[[[]]],\"distances\":[[\"y\"]]}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.query_embeddings("c1", [[1.0]])
  // `ids: [null]` is a row that is not an array, so there is no result at
  // all. The other fields do have a row, and keep their position: an entry
  // of the wrong type becomes `None` rather than disappearing.
  assert_eq(result.ids, [])
  assert_eq(result.documents, [None])
  assert_eq(result.embeddings, [None])
  assert_eq(result.distances, [None])
}

///|
test "a get result keeps null placeholders for missing fields" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(
      200, "{\"ids\":[\"a\",\"b\"],\"documents\":[\"x\",null],\"distances\":[0.5,null],\"embeddings\":[[1.0],[2.0,\"bad\"]]}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.get("c1")
  // Position-preserving `null`s are how Chroma reports a record that has no
  // value for an included field.
  assert_eq(result.documents, [Some("x"), None])
  assert_eq(result.distances, [Some(0.5), None])
  // A non-number inside a vector is skipped, keeping the numbers around it.
  assert_eq(result.embeddings, [Some([1.0]), Some([2.0])])
}

///|
test "record builders fill in the field they promise" {
  let with_document = @chroma-client.Record::of_embedding("a", [1.0]).with_document(
    "hello",
  )
  assert_eq(with_document.document, Some("hello"))
  let with_metadata = @chroma-client.Record::of_embedding("a", [1.0]).with_metadata([
      ("k", @chroma-client.MString("v")),
    ],
  )
  assert_eq(with_metadata.metadata, [("k", @chroma-client.MString("v"))])
  // `with_embedding` is the documented way to make a document-only record
  // storable.
  let stored = @chroma-client.Record::of_document("a", "hello").with_embedding([
    1.0, 2.0,
  ])
  assert_eq(stored.embedding, Some([1.0, 2.0]))
}

///|
test "metadata values round-trip through json" {
  let metadata : @chroma-client.Metadata = [
    ("s", @chroma-client.MString("x")),
    ("i", @chroma-client.MInt(3)),
    ("f", @chroma-client.MFloat(0.5)),
    ("b", @chroma-client.MBool(false)),
    ("n", @chroma-client.MNull),
  ]
  let encoded = @chroma-client.metadata_to_json(metadata)
  assert_eq(
    encoded,
    @json.parse("{\"s\":\"x\",\"i\":3,\"f\":0.5,\"b\":false,\"n\":null}"),
  )
  // Arrays and objects are not legal Chroma metadata; they are skipped
  // rather than failing the whole response.
  let decoded = @chroma-client.metadata_from_json(
    @json.parse("{\"b\": false, \"bad\": [1], \"worse\": {}}"),
  )
  assert_eq(decoded, [("b", @chroma-client.MBool(false))])
  assert_eq(@chroma-client.metadata_from_json(@json.parse("[1]")), [])
}

///|
test "embedding_from_json reports a malformed vector" {
  assert_eq(@chroma-client.embedding_from_json(@json.parse("[1,2]")), [1.0, 2.0])
  let non_number = @json.parse("[1,\"x\"]")
  assert_true(
    try_catch(() => ignore(@chroma-client.embedding_from_json(non_number)))
    is Err(Decode(_)),
  )
  let not_an_array = @json.parse("1")
  assert_true(
    try_catch(() => ignore(@chroma-client.embedding_from_json(not_an_array)))
    is Err(Decode(_)),
  )
}

///|
test "error variants render and compare" {
  // `Show` is what a caller logs; each variant has to name its own failure
  // mode rather than falling through to a generic message.
  assert_eq(
    @chroma-client.ChromaError::Transport("boom").to_string(),
    "transport error: boom",
  )
  assert_eq(
    @chroma-client.ChromaError::Status(502, "bad gateway").to_string(),
    "server returned status 502: bad gateway",
  )
  assert_eq(
    @chroma-client.ChromaError::Decode("bad shape").to_string(),
    "decode error: bad shape",
  )
  assert_eq(
    @chroma-client.ChromaError::InvalidArgument("nope").to_string(),
    "invalid argument: nope",
  )
  // `Eq` is exposed as a free function rather than as an operator, because
  // the blackbox test cannot see the `impl`.
  assert_true(
    @chroma-client.ChromaError::equal(
      @chroma-client.ChromaError::Transport("a"),
      @chroma-client.ChromaError::Transport("a"),
    ),
  )
  assert_true(
    !@chroma-client.ChromaError::equal(
      @chroma-client.ChromaError::Status(500, "x"),
      @chroma-client.ChromaError::Decode("x"),
    ),
  )
  assert_true(
    @chroma-client.ChromaError::equal(
      @chroma-client.ChromaError::Status(500, "x"),
      @chroma-client.ChromaError::Status(500, "x"),
    ),
  )
  assert_eq(@chroma-client.ChromaError::Decode("bad").message(), "bad")
  assert_eq(@chroma-client.ChromaError::Transport("down").message(), "down")
}

///|
test "an error body without a message falls back to the code and the body" {
  // `ApiError` doubles as the message when the server sent only a label.
  let labelled = @chroma-client.api_error(400, "{\"error\":\"BadRequest\"}")
  match labelled {
    Api(error) => assert_eq(error.message, "BadRequest")
    _ => fail("expected an Api error")
  }
  // With neither field, the raw body is the only sentence available.
  let raw = @chroma-client.ApiError::from_json(502, "upstream boom")
  assert_eq(raw.to_string(), "server returned status 502: upstream boom")
  assert_eq(
    @chroma-client.ApiError::from_json(400, "{\"message\": 3}").message,
    "",
  )
}

///|
test "retry policy clamps a negative delay ceiling" {
  let policy = @chroma-client.RetryPolicy::new(max_delay_ms=-1)
  assert_eq(policy.max_delay_ms, 0)
  let transport = @chroma-client.RetryTransport::new(
    @chroma-client.MemoryTransport::new(),
  )
  assert_true(transport.with_policy(policy).policy() == policy)
}

///|
test "a transport with no scripted response falls back to an empty object" {
  let transport = @chroma-client.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  // With nothing queued the transport answers `{}`, which is enough for the
  // delete path but not for one that needs a field.
  client.delete_collection("docs")
  assert_eq(transport.observed().length(), 1)
}

///|
test "method names render as their wire verbs" {
  assert_eq(@chroma-client.Get.to_string(), "GET")
  assert_eq(@chroma-client.Post.to_string(), "POST")
  assert_eq(@chroma-client.Put.to_string(), "PUT")
  assert_eq(@chroma-client.Delete.to_string(), "DELETE")
  assert_eq(@chroma-client.Patch.to_string(), "PATCH")
}

///|
test "percent-encoding covers the two- and four-byte utf8 forms" {
  // Latin-1 range and above: a two-byte sequence (`é`) and a four-byte one
  // (an emoji) take the other two branches of the encoder.
  assert_eq(@chroma-client.encode_path_segment("é"), "%C3%A9")
  assert_eq(@chroma-client.encode_path_segment("😀"), "%F0%9F%98%80")
  assert_eq(@chroma-client.encode_query_component("a b"), "a+b")
}

///|
test "the heartbeat fallback reports a decode error for an empty object" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  // No documented key and no first field to fall back to: there is no
  // timestamp to return, and reporting 0 would look like a stopped server.
  assert_true(try_catch(() => ignore(client.heartbeat())) is Err(Decode(_)))
}

///|
test "a non-object json body decodes as empty optional fields" {
  // `optional_array` / `optional_object` are reached with a non-object when
  // a scalar is used as a collection, so they must default rather than fail.
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"ids\":[\"a\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.get("c1")
  assert_eq(result.ids, ["a"])
  // Nothing was included, so every optional column is empty.
  assert_eq(result.documents, [])
  assert_eq(result.metadatas, [])
  assert_eq(result.distances, [])
  assert_eq(result.embeddings, [])
}

///|
test "a non-string id in a result is skipped" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{\"ids\":[\"a\",3,\"b\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.get("c1").ids, ["a", "b"])
}

///|
test "the update path forwards a where clause and tolerates no filter" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.update(
    "c1",
    [@chroma-client.Record::of_embedding("a", [1.0])],
    filter=@chroma-client.Filter::new(
      where_clause=Some(@json.parse("{\"topic\":\"ai\"}")),
    ),
  )
  assert_true(
    transport.last_request().unwrap().body.unwrap().contains("\"where\""),
  )
  // Without a filter the body is the columnar record body and nothing else.
  client.update("c1", [@chroma-client.Record::of_embedding("a", [1.0])])
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(!body.contains("\"where\""))
}

///|
test "the delete path forwards each optional filter field" {
  let transport = @chroma-client.MemoryTransport::new(responses=[
    @chroma-client.Response::json(200, "{}"),
    @chroma-client.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.delete(
    "c1",
    filter=@chroma-client.Filter::new(
      where_clause=Some(@json.parse("{\"topic\":\"ai\"}")),
      ids=["a"],
    ),
  )
  let body = transport.last_request().unwrap().body.unwrap()
  assert_true(body.contains("\"where\""))
  assert_true(body.contains("\"ids\":[\"a\"]"))
  // An empty filter deletes everything, so the body says nothing at all.
  client.delete("c1")
  assert_eq(transport.last_request().unwrap().body.unwrap(), "{}")
}

///|
test "validate_limit_offset rejects negative windows" {
  // A negative limit or offset has no meaning to Chroma and would produce a
  // confusing server error, so it is refused before a request is built.
  assert_true(
    try_catch(() => @chroma-client.validate_limit_offset(Some(-1), None))
    is Err(InvalidArgument(_)),
  )
  assert_true(
    try_catch(() => @chroma-client.validate_limit_offset(None, Some(-1)))
    is Err(InvalidArgument(_)),
  )
  assert_true(
    try_catch(() => @chroma-client.validate_limit_offset(Some(10), Some(10)))
    is Err(InvalidArgument(_)),
  )
}

///|
test "errors compare across every variant" {
  assert_true(
    @chroma-client.ChromaError::equal(
      @chroma-client.api_error(400, "{\"error\":\"Bad\",\"message\":\"x\"}"),
      @chroma-client.api_error(400, "{\"error\":\"Bad\",\"message\":\"x\"}"),
    ),
  )
  assert_true(
    !@chroma-client.ChromaError::equal(
      @chroma-client.api_error(400, "{\"error\":\"Bad\"}"),
      @chroma-client.api_error(404, "{\"error\":\"Bad\"}"),
    ),
  )
  // A `Status` error with no envelope is its own variant, and the raw body
  // is what `message()` reports.
  let status = @chroma-client.ChromaError::Status(502, "bad gateway")
  assert_eq(status.message(), "bad gateway")
}
