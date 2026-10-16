///|
/// End-to-end tests against a real Chroma server.
///
/// These exercise the wire protocol itself: the columnar record body, the
/// `get_or_create` flag, and the response shape of `count` / `heartbeat`.
/// Each one was written after a live server rejected or reshaped something
/// `MemoryTransport` had happily accepted — scripted responses only prove the
/// client agrees with itself.
///
/// Every test returns early when `CHROMA_ENDPOINT` is unset, so the suite is
/// a no-op off the integration job.

///|
async test "heartbeat reports a reachable server" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  // Chroma answers `{"nanosecond heartbeat": <ns>}`; reading the field
  // wrongly used to yield 0 for a perfectly healthy server.
  assert_true(client.heartbeat_async() > 0)
}

///|
async test "version returns the server's version string" {
  guard chroma_endpoint() is Some(_) else { return }
  assert_true(live_client().version_async().length() > 0)
}

///|
async test "get_or_create_collection is idempotent" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("idempotent")
  defer (client.delete_collection_async(name) catch { _ => () })
  let first = client.get_or_create_collection_async(name)
  // Without `get_or_create: true` the server answers 409 here, which is the
  // bug this asserts against.
  let second = client.get_or_create_collection_async(name)
  assert_eq(first.id, second.id)
  assert_eq(first.name, name)
}

///|
async test "create_collection refuses a duplicate name" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("duplicate")
  defer (client.delete_collection_async(name) catch { _ => () })
  ignore(client.create_collection_async(name))
  let result = try_async(() => ignore(client.create_collection_async(name)))
  match result {
    Err(@chroma.ChromaError::Api(error)) => assert_eq(error.status, 409)
    Err(error) => fail("expected a 409 conflict, got " + error.to_string())
    Ok(_) => fail("expected a 409 conflict, but the call succeeded")
  }
}

///|
async test "add stores columnar records and count reads back" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("add", (client, collection) => {
    // A row-shaped body (`{"records": [...]}`) is rejected by the server with
    // 422, and that is exactly what the client used to send.
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("a", [1.0, 0.0, 0.0], metadata=[
        ("topic", @chroma.MString("language")),
      ]),
      @chroma.Record::of_embedding("b", [0.0, 1.0, 0.0]),
    ])
    client.add_async(collection.id, [
      @chroma.Record::of_document("c", "a document with a vector").with_embedding([
          0.0, 0.0, 1.0,
        ],
      ),
    ])
    // `count` answers with a bare integer, not `{"count": 3}`.
    assert_eq(client.count_async(collection.id), 3)
  })
}

///|
async test "query returns ids, distances and metadata" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("query", (client, collection) => {
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("near", [1.0, 0.0], metadata=[
        ("kind", @chroma.MString("near")),
      ]),
      @chroma.Record::of_embedding("far", [0.0, 1.0], metadata=[
        ("kind", @chroma.MString("far")),
      ]),
    ])
    let result = client.query_embeddings_async(
      collection.id,
      [[1.0, 0.0]],
      n_results=2,
    )
    // The query response nests one row per query embedding; the client
    // flattens the first.
    assert_eq(result.ids, ["near", "far"])
    assert_eq(result.distances[0], Some(0.0))
    assert_eq(result.metadatas[0], [("kind", MString("near"))])
  })
}

///|
async test "get filters by metadata" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("get-filter", (client, collection) => {
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("a", [1.0, 0.0], metadata=[
        ("topic", @chroma.MString("language")),
      ]),
      @chroma.Record::of_embedding("b", [0.0, 1.0], metadata=[
        ("topic", @chroma.MString("database")),
      ]),
    ])
    let filtered = client.get_async(
      collection.id,
      filter=@chroma.Filter::new().with_metadata(
        "topic",
        @chroma.MString("language"),
      ),
    )
    assert_eq(filtered.ids, ["a"])
  })
}

///|
async test "update patches only the fields it is given" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("update", (client, collection) => {
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("a", [1.0, 0.0], metadata=[
        ("topic", @chroma.MString("before")),
      ]),
    ])
    // An update that carries only metadata must not erase the vector, which
    // is what a `null` column entry means on the wire.
    client.update_async(collection.id, [
      {
        id: "a",
        document: None,
        embedding: None,
        metadata: [("topic", MString("after"))],
      },
    ])
    let fetched = client.get_async(
      collection.id,
      filter=@chroma.Filter::new().with_limit(10),
    )
    assert_eq(fetched.ids, ["a"])
    assert_eq(fetched.metadatas[0], [("topic", MString("after"))])
  })
}

///|
async test "delete removes records by id and leaves the rest" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("delete", (client, collection) => {
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("keep", [1.0, 0.0]),
      @chroma.Record::of_embedding("drop", [0.0, 1.0]),
    ])
    client.delete_async(collection.id, filter=@chroma.Filter::new(ids=["drop"]))
    assert_eq(client.count_async(collection.id), 1)
  })
}

///|
async test "upsert replaces an existing id" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("upsert", (client, collection) => {
    client.add_async(collection.id, [
      @chroma.Record::of_embedding("a", [1.0, 0.0], metadata=[
        ("v", @chroma.MString("1")),
      ]),
    ])
    client.upsert_async(collection.id, [
      @chroma.Record::of_embedding("a", [0.0, 1.0], metadata=[
        ("v", @chroma.MString("2")),
      ]),
    ])
    // upsert must not turn a replace into an insert.
    assert_eq(client.count_async(collection.id), 1)
    assert_eq(
      client.get_async(
        collection.id,
        filter=@chroma.Filter::new().with_limit(10),
      ).metadatas[0],
      [("v", MString("2"))],
    )
  })
}

///|
async test "list_collections includes the collection just created" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("list")
  defer (client.delete_collection_async(name) catch { _ => () })
  ignore(client.get_or_create_collection_async(name))
  let names : Array[String] = []
  for collection in client.list_collections_async() {
    names.push(collection.name)
  }
  assert_true(names.contains(name))
}

///|
async test "get_collection returns None for a missing name" {
  guard chroma_endpoint() is Some(_) else { return }
  let missing = live_client().get_collection_async(unique_name("missing"))
  assert_true(missing is None)
}

///|
async test "an error status carries the server's message" {
  guard chroma_endpoint() is Some(_) else { return }
  // A malformed id makes Chroma answer 400 with a JSON envelope; the client
  // must surface that as a parsed `Api` error rather than a bare status.
  let client = live_client()
  let result = try_async(() => {
    client.add_async("not-a-uuid", [@chroma.Record::of_embedding("a", [1.0])])
  })
  match result {
    Err(@chroma.ChromaError::Api(error)) => {
      assert_true(error.status == 400 || error.status == 404)
      assert_true(error.message != "")
    }
    Err(error) => fail("expected a parsed API error, got " + error.to_string())
    Ok(_) => fail("expected a parsed API error, but the call succeeded")
  }
}

///|
/// Runs a raising async thunk and reports the error as a `Result`.
async fn try_async(
  f : async () -> Unit raise @chroma.ChromaError,
) -> Result[Unit, @chroma.ChromaError] {
  try {
    f()
    Ok(())
  } catch {
    error => Err(error)
  }
}
