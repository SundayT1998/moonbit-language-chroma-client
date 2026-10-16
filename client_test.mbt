///|
test "collection decodes required and optional fields" {
  let raw =
    #|{
    #|  "id": "c1",
    #|  "name": "notes",
    #|  "metadata": { "topic": "ai", "size": 3, "ratio": 1.5, "pinned": true },
    #|  "configuration": { "hnsw": { "space": "l2" } },
    #|  "log_position": 7,
    #|  "version": 2
    #|}
  let json = @json.parse(raw)
  let collection = @chroma-client.Collection::from_json(json)
  assert_eq(collection.id, "c1")
  assert_eq(collection.name, "notes")
  assert_eq(collection.log_position, 7)
  assert_eq(collection.version, 2)
  assert_eq(collection.metadata, [
    ("topic", MString("ai")),
    ("size", MInt(3)),
    ("ratio", MFloat(1.5)),
    ("pinned", MBool(true)),
  ])
}

///|
test "collection tolerates missing optional fields" {
  let collection = @chroma-client.Collection::from_json(
    @json.parse("{\"id\":\"c1\",\"name\":\"notes\"}"),
  )
  assert_eq(collection.log_position, 0)
  assert_eq(collection.version, 0)
  assert_eq(collection.metadata, [])
}

///|
test "collection requires id and name" {
  let json = @json.parse("{\"name\":\"notes\"}")
  let failed = try {
    ignore(@chroma-client.Collection::from_json(json))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "list_collections builds a v2 request and decodes the array" {
  let collections_payload = "[{\"id\":\"c1\",\"name\":\"notes\"},{\"id\":\"c2\",\"name\":\"docs\"}]"
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, collections_payload),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let collections = client.list_collections()
  assert_eq(collections.length(), 2)
  assert_eq(collections[0].name, "notes")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @http.Get)
  assert_eq(
    request.url,
    "http://localhost:8000/api/v2/tenants/default_tenant/databases/default_database/collections",
  )
  assert_true(request.body is None)
}

///|
test "count_collections reads the count field" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\": 4}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.count_collections(), 4)
}

///|
test "create_collection posts the name and embedding function" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"id\":\"c3\",\"name\":\"wiki\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let collection = client.create_collection(
    "wiki",
    config=@chroma-client.CollectionConfig::new(
      embedding_function=Some("default"),
      metadata=[("purpose", MString("docs"))],
    ),
  )
  assert_eq(collection.id, "c3")
  assert_eq(collection.name, "wiki")
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @http.Post)
  let body = @json.parse(request.body.unwrap())
  assert_eq(required_string(body, "name"), "wiki")
  let configuration = required_object(body, "configuration")
  assert_eq(
    required_string(required_object(configuration, "hnsw"), "space"),
    "l2",
  )
  let embedding = required_object(body, "embedding_function")
  assert_eq(required_string(embedding, "name"), "default")
  let metadata = required_object(body, "metadata")
  assert_eq(required_string(metadata, "purpose"), "docs")
}

///|
test "get_collection returns None on 404" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(404, "{\"error\":\"not found\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_true(client.get_collection("missing") is None)
}

///|
test "get_collection percent-encodes the name" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"id\":\"c1\",\"name\":\"my notes\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let collection = client.get_collection("my notes").unwrap()
  assert_eq(collection.name, "my notes")
  assert_true(transport.last_request().unwrap().url.contains("my%20notes"))
}

///|
test "non-2xx responses surface as a status error" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(500, "{\"error\":\"boom\"}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.list_collections()))
  match result {
    Err(Status(code, body)) => {
      assert_eq(code, 500)
      assert_true(body.contains("boom"))
    }
    _ => fail("expected a Status error")
  }
}

///|
test "invalid json bodies surface as a decode error" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "not json"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.list_collections()))
  assert_true(result is Err(Decode(_)))
}

///|
/// Test-local field readers, mirroring the internal helpers.
fn required_object(json : Json, key : String) -> Json raise {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => fail("missing field " + key)
      }
    _ => fail("expected object")
  }
}

///|
fn required_string(json : Json, key : String) -> String raise {
  match required_object(json, key) {
    Json::String(s) => s
    _ => fail("field " + key + " is not a string")
  }
}

///|
test "add serializes records with documents, embeddings and metadata" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.add("c1", [
    @chroma-client.Record::of_document("r1", "hello", metadata=[
      ("tag", MString("greeting")),
    ]),
    @chroma-client.Record::of_embedding("r2", [0.5, 0.25], metadata=[
      ("n", MInt(2)),
    ]),
  ])
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @http.Post)
  assert_true(request.url.has_suffix("/collections/c1/add"))
  let body = @json.parse(request.body.unwrap())
  let records = required_array(body, "records")
  assert_eq(records.length(), 2)
  assert_eq(required_string(records[0], "id"), "r1")
  assert_eq(required_string(records[0], "document"), "hello")
  assert_eq(required_string(records[1], "id"), "r2")
  assert_eq(required_array(records[1], "embedding").length(), 2)
}

///|
test "query_text posts the query and flattens the per-query nesting" {
  let query_payload =
    #|{
    #|  "ids": [["r1", "r2"]],
    #|  "documents": [["alpha", "beta"]],
    #|  "metadatas": [[{"tag": "x"}, {"tag": "y"}]],
    #|  "distances": [[0.1, 0.2]]
    #|}
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, query_payload),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.query_text("c1", ["alpha"], n_results=2)
  assert_eq(result.ids, ["r1", "r2"])
  assert_eq(result.documents, [Some("alpha"), Some("beta")])
  assert_eq(result.distances, [Some(0.1), Some(0.2)])
  assert_eq(result.metadatas, [[("tag", MString("x"))], [("tag", MString("y"))]])
  // embeddings were not requested, so the field is absent from the response
  assert_eq(result.embeddings, [])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(required_array(body, "query_texts").length(), 1)
  assert_eq(required_array(body, "include").length(), 3)
}

///|
test "query_embeddings sends vectors directly" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(
      200, "{\"ids\":[[\"r1\"]],\"embeddings\":[[[1.0,2.0]]]}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.query_embeddings(
    "c1",
    [[1.0, 2.0]],
    include_fields=@chroma-client.Include::all(),
  )
  assert_eq(result.ids, ["r1"])
  assert_eq(result.embeddings, [Some([1.0, 2.0])])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(required_array(body, "query_embeddings").length(), 1)
  assert_eq(required_array(body, "include").length(), 4)
}

///|
test "filter builds a where clause and a limit" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[\"r1\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new()
    .with_metadata("tag", MString("x"))
    .with_limit(5)
  let result = client.get("c1", filter~)
  assert_eq(result.ids, ["r1"])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  let clause = required_object(body, "where")
  let tag = required_object(clause, "tag")
  assert_eq(required_string(tag, "$eq"), "x")
}

///|
test "delete sends ids and where clauses" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.delete("c1", filter=@chroma-client.Filter::new(ids=["r1", "r2"]))
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(required_array(body, "ids").length(), 2)
}

///|
test "heartbeat and version read scalar responses" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "1234"),
    @http.Response::json(200, "\"1.0.0\""),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.heartbeat(), 1234)
  assert_eq(client.version(), "1.0.0")
}

///|
test "config customisation changes the api prefix" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\":0}"),
  ])
  let client = @chroma-client.ChromaClient::new(
    transport,
    config=@chroma-client.Config::new(
      endpoint="https://chroma.example.com/",
      tenant="acme",
      database="prod db",
    ),
  )
  ignore(client.count_collections())
  assert_eq(
    transport.last_request().unwrap().url,
    "https://chroma.example.com/api/v2/tenants/acme/databases/prod%20db/collections_count",
  )
}

///|
test "custom headers are merged into every request" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\":0}"),
  ])
  let client = @chroma-client.ChromaClient::new(
    transport,
    config=@chroma-client.Config::new(headers={
      "authorization": "Bearer token",
    }),
  )
  ignore(client.count_collections())
  let headers = transport.last_request().unwrap().headers
  assert_eq(headers.get("authorization"), Some("Bearer token"))
  assert_eq(headers.get("content-type"), Some("application/json"))
}

///|
test "transport failures surface as a transport error" {
  let client = @chroma-client.ChromaClient::new(FailingTransport::new())
  let result = try_catch(() => ignore(client.list_collections()))
  match result {
    Err(Transport(message)) =>
      assert_true(message.contains("connection refused"))
    _ => fail("expected a Transport error")
  }
}

///|
/// Reads a required array field for assertions.
fn required_array(json : Json, key : String) -> Array[Json] raise {
  match required_object(json, key) {
    Json::Array(items) => items
    _ => fail("field " + key + " is not an array")
  }
}

///|
/// A transport that always fails, used to check error mapping.
struct FailingTransport {
  marker : Int32
}

///|
fn FailingTransport::new() -> FailingTransport {
  { marker: 0, }
}

///|
impl @http.Transport for FailingTransport with fn send(self, _) {
  raise Failure::Failure("connection refused " + self.marker.to_string())
}

///|
/// Runs a raising thunk and reports the error as a `Result`.
fn try_catch(
  f : () -> Unit raise @chroma-client.ChromaError,
) -> Result[Unit, @chroma-client.ChromaError] {
  try {
    f()
    Ok(())
  } catch {
    error => Err(error)
  }
}

///|
test "with_token and with_basic_auth stamp the authorization header" {
  let base = @chroma-client.Config::new()
  let bearer = base.with_token("s3cret")
  assert_eq(bearer.headers.get("authorization"), Some("Bearer s3cret"))
  // the original config is untouched
  assert_eq(base.headers.length(), 0)

  let basic = base.with_basic_auth("alice", "hunter2")
  assert_eq(
    basic.headers.get("authorization"),
    Some("Basic YWxpY2U6aHVudGVyMg=="),
  )
}

///|
test "authentication headers reach every request" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\":0}"),
  ])
  let client = @chroma-client.ChromaClient::new(
    transport,
    config=@chroma-client.Config::new().with_token("t"),
  )
  ignore(client.count_collections())
  assert_eq(
    transport.last_request().unwrap().headers.get("authorization"),
    Some("Bearer t"),
  )
}

///|
test "with_headers merges without mutating the receiver" {
  let base = @chroma-client.Config::new(headers={ "x-base": "1" })
  let merged = base.with_headers({ "x-extra": "2" })
  assert_eq(merged.headers.get("x-base"), Some("1"))
  assert_eq(merged.headers.get("x-extra"), Some("2"))
  assert_eq(base.headers.get("x-extra"), None)
}

///|
test "with_token overrides an earlier Authorization header" {
  let config = @chroma-client.Config::new(headers={
    "authorization": "Bearer stale",
  }).with_token("fresh")
  assert_eq(config.headers.get("authorization"), Some("Bearer fresh"))
  assert_eq(config.headers.length(), 1)
}

///|
test "timeout transport stamps the deadline header" {
  let inner = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\":0}"),
  ])
  let client = @chroma-client.ChromaClient::new(
    @chroma-client.TimeoutTransport::new(inner, 5000),
  )
  ignore(client.count_collections())
  let request = inner.last_request().unwrap()
  assert_eq(request.headers.get(@chroma-client.TIMEOUT_HEADER), Some("5000"))
}

///|
test "timeout transport passes requests through when disabled" {
  let inner = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\":0}"),
  ])
  let client = @chroma-client.ChromaClient::new(
    @chroma-client.TimeoutTransport::from_config(
      inner,
      @chroma-client.Config::new(timeout_ms=0),
    ),
  )
  ignore(client.count_collections())
  assert_eq(
    inner.last_request().unwrap().headers.get(@chroma-client.TIMEOUT_HEADER),
    None,
  )
}

///|
test "count reads the collection record count" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"count\": 17}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.count("c1"), 17)
  let request = transport.last_request().unwrap()
  assert_eq(request.verb, @http.Get)
  assert_true(request.url.has_suffix("/collections/c1/count"))
}

///|
test "peek posts a bounded limit and decodes a flat result" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(
      200, "{\"ids\":[\"r1\",\"r2\"],\"documents\":[\"a\",\"b\"]}",
    ),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = client.peek("c1", limit=2)
  assert_eq(result.ids, ["r1", "r2"])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(
    body,
    @json.parse(
      "{\"limit\":2,\"include\":[\"documents\",\"metadatas\",\"distances\"]}",
    ),
  )
}

///|
test "peek clamps out-of-range limits" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[]}"),
    @http.Response::json(200, "{\"ids\":[]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  ignore(client.peek("c1", limit=0))
  ignore(client.peek("c1", limit=9999))
  let observed = transport.observed()
  let first = @json.parse(observed[0].body.unwrap())
  let second = @json.parse(observed[1].body.unwrap())
  assert_eq(
    first,
    @json.parse(
      "{\"limit\":1,\"include\":[\"documents\",\"metadatas\",\"distances\"]}",
    ),
  )
  assert_eq(
    second,
    @json.parse(
      "{\"limit\":100,\"include\":[\"documents\",\"metadatas\",\"distances\"]}",
    ),
  )
}

///|
test "get rejects an offset that is not smaller than the limit" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new(limit=Some(10), offset=Some(10))
  let result = try_catch(() => ignore(client.get("c1", filter~)))
  assert_true(result is Err(InvalidArgument(_)))
  // nothing was sent
  assert_eq(transport.observed().length(), 0)
}

///|
test "get accepts an offset smaller than the limit" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[\"r1\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new(limit=Some(10), offset=Some(5))
  assert_eq(client.get("c1", filter~).ids, ["r1"])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(body, @json.parse("{\"limit\":10,\"offset\":5}"))
}

///|
test "get tolerates an offset without a limit" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new(offset=Some(99))
  ignore(client.get("c1", filter~))
  assert_eq(transport.observed().length(), 1)
}

///|
test "get reports a missing ids field as a decode error" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"documents\":[\"a\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.get("c1")))
  assert_true(result is Err(Decode(_)))
}

///|
test "query rejects a non-positive n_results" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => {
    ignore(client.query_text("c1", ["x"], n_results=0))
  })
  assert_true(result is Err(InvalidArgument(_)))
  assert_eq(transport.observed().length(), 0)
}

///|
test "query forwards where clauses but not the pagination window" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[[\"r1\"]]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let filter = @chroma-client.Filter::new(
    where_clause=Some(@json.parse("{\"tag\":{\"$eq\":\"x\"}}")),
  )
  ignore(client.query_text("c1", ["x"], filter~))
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(
    body,
    @json.parse(
      "{\"query_texts\":[\"x\"],\"n_results\":10,\"include\":[\"documents\",\"metadatas\",\"distances\"],\"where\":{\"tag\":{\"$eq\":\"x\"}}}",
    ),
  )
}

///|
test "record-level embedding function override is serialized" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let record = @chroma-client.Record::of_document("r1", "hello").with_embedding_function(
    @json.parse("{\"name\":\"custom\"}"),
  )
  client.add("c1", [record])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(
    required_object(required_array(body, "records")[0], "embedding_function"),
    @json.parse("{\"name\":\"custom\"}"),
  )
}

///|
test "embedding function override requires a document" {
  let record = @chroma-client.Record::of_embedding("r1", [1.0])
  let config = @json.parse("{\"name\":\"custom\"}")
  let result = try_catch(() => ignore(record.with_embedding_function(config)))
  assert_true(result is Err(InvalidArgument(_)))
}

///|
test "records without an override leave the field out" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  client.add("c1", [@chroma-client.Record::of_document("r1", "hello")])
  let body = @json.parse(transport.last_request().unwrap().body.unwrap())
  assert_eq(
    body,
    @json.parse("{\"records\":[{\"id\":\"r1\",\"document\":\"hello\"}]}"),
  )
}

///|
test "collection tolerant of missing optional fields still requires id" {
  let json = @json.parse("{\"name\":\"n\"}")
  let result = try_catch(() => {
    ignore(@chroma-client.Collection::from_json(json))
  })
  assert_true(result is Err(Decode(_)))
}

///|
test "validate_limit_offset accepts an empty window" {
  @chroma-client.validate_limit_offset(None, None) catch {
    _ => fail("unexpected error")
  }
  @chroma-client.validate_limit_offset(Some(10), None) catch {
    _ => fail("unexpected error")
  }
}
