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
/// a no-op in ordinary `moon test` runs and only does work in the CI job that
/// starts a server.

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
    Err(ChromaError::Api(error)) => assert_eq(error.status, 409)
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
      Record::of_embedding("a", [1.0, 0.0, 0.0], metadata=[
        ("topic", MString("language")),
      ]),
      Record::of_embedding("b", [0.0, 1.0, 0.0]),
    ])
    client.add_async(collection.id, [
      Record::of_document("c", "a document with a vector").with_embedding([
        0.0, 0.0, 1.0,
      ]),
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
      Record::of_embedding("near", [1.0, 0.0], metadata=[
        ("kind", MString("near")),
      ]),
      Record::of_embedding("far", [0.0, 1.0], metadata=[
        ("kind", MString("far")),
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
      Record::of_embedding("a", [1.0, 0.0], metadata=[
        ("topic", MString("language")),
      ]),
      Record::of_embedding("b", [0.0, 1.0], metadata=[
        ("topic", MString("database")),
      ]),
    ])
    let filtered = client.get_async(
      collection.id,
      filter=Filter::new().with_metadata("topic", MString("language")),
    )
    assert_eq(filtered.ids, ["a"])
  })
}

///|
async test "update patches only the fields it is given" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("update", (client, collection) => {
    client.add_async(collection.id, [
      Record::of_embedding("a", [1.0, 0.0], metadata=[
        ("topic", MString("before")),
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
      filter=Filter::new().with_limit(10),
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
      Record::of_embedding("keep", [1.0, 0.0]),
      Record::of_embedding("drop", [0.0, 1.0]),
    ])
    client.delete_async(collection.id, filter=Filter::new(ids=["drop"]))
    assert_eq(client.count_async(collection.id), 1)
  })
}

///|
async test "upsert replaces an existing id" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("upsert", (client, collection) => {
    client.add_async(collection.id, [
      Record::of_embedding("a", [1.0, 0.0], metadata=[("v", MString("1"))]),
    ])
    client.upsert_async(collection.id, [
      Record::of_embedding("a", [0.0, 1.0], metadata=[("v", MString("2"))]),
    ])
    // upsert must not turn a replace into an insert.
    assert_eq(client.count_async(collection.id), 1)
    assert_eq(
      client.get_async(collection.id, filter=Filter::new().with_limit(10)).metadatas[0],
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
async test "count_collections counts the collections in the database" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("count-collections")
  defer (client.delete_collection_async(name) catch { _ => () })
  // The endpoint answers with a bare integer and, unlike
  // `collections/{id}/count`, over the whole database: create one collection
  // and the count has to include it.
  let before = client.count_collections_async()
  ignore(client.get_or_create_collection_async(name))
  assert_true(client.count_collections_async() > before)
}

///|
async test "get_collection returns the collection just created" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("get")
  defer (client.delete_collection_async(name) catch { _ => () })
  let created = client.get_or_create_collection_async(name)
  let fetched = client.get_collection_async(name).unwrap()
  // The lookup goes through the same `/collections/{id}` endpoint the create
  // response came from, so a wrong path would not find it.
  assert_eq(fetched.id, created.id)
  assert_eq(fetched.name, name)
}

///|
async test "modify_collection renames and replaces metadata" {
  guard chroma_endpoint() is Some(_) else { return }
  let client = live_client()
  let name = unique_name("modify")
  let renamed = unique_name("modify-renamed")
  defer (client.delete_collection_async(renamed) catch { _ => () })
  ignore(
    client.get_or_create_collection_async(
      name,
      config=CollectionConfig::new(metadata=[("keep", MString("yes"))]),
    ),
  )
  // `new_metadata` is the field name the server actually reads; sending
  // `metadata` is silently ignored, and nothing but a live server catches it.
  client.modify_collection_async(
    name,
    new_name=Some(renamed),
    metadata=Some([("topic", MString("changed"))]),
  )
  let modified = client.get_collection_async(renamed).unwrap()
  assert_eq(modified.name, renamed)
  assert_eq(modified.metadata, [("topic", MString("changed"))])
}

///|
async test "peek returns at most the limit it was given" {
  guard chroma_endpoint() is Some(_) else { return }
  with_collection("peek", (client, collection) => {
    client.add_async(collection.id, [
      Record::of_embedding("a", [1.0, 0.0]),
      Record::of_embedding("b", [0.0, 1.0]),
      Record::of_embedding("c", [1.0, 1.0]),
    ])
    // `peek` posts to `/get` with a limit, so the server is what decides the
    // page size: asking for 2 of the 3 records has to come back with 2.
    let peeked = client.peek_async(collection.id, limit=2)
    assert_eq(peeked.ids.length(), 2)
    assert_eq(client.peek_async(collection.id, limit=99).ids.length(), 3)
  })
}

///|
async test "an error status carries the server's message" {
  guard chroma_endpoint() is Some(_) else { return }
  // A malformed id makes Chroma answer 400 with a JSON envelope; the client
  // must surface that as a parsed `Api` error rather than a bare status.
  let client = live_client()
  let result = try_async(() => {
    client.add_async("not-a-uuid", [Record::of_embedding("a", [1.0])])
  })
  match result {
    Err(ChromaError::Api(error)) => {
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
  f : async () -> Unit raise ChromaError,
) -> Result[Unit, ChromaError] {
  try {
    f()
    Ok(())
  } catch {
    error => Err(error)
  }
}

///|
/// The endpoint of the Chroma server under test, or `None` when the suite
/// should be skipped.
///
/// These tests only run when `CHROMA_ENDPOINT` is set. That keeps
/// `moon test` green on a laptop with no Docker daemon and on the GitHub
/// Actions matrix (macOS and Windows do not get a Chroma container), while CI
/// jobs that do start a server opt in by exporting the variable.
fn chroma_endpoint() -> String? {
  @env.get_env_var("CHROMA_ENDPOINT")
}

///|
/// Builds a client pointed at the server under test.
fn live_client() -> ChromaClient[AsyncHttpTransport] {
  let endpoint = chroma_endpoint().unwrap()
  ChromaClient::new(AsyncHttpTransport::new(), config=Config::new(endpoint~))
}

///|
/// A collection name that no other run can collide with.
///
/// A shared server (the CI sidecar is one) is used by parallel tests, so the
/// name carries a caller-supplied tag plus a run id. The tag keeps a failing
/// test's leftovers identifiable in `list_collections`.
fn unique_name(tag : String) -> String {
  let suffix = match @env.get_env_var("CHROMA_TEST_RUN_ID") {
    Some(value) if value != "" => value
    _ => "local"
  }
  "chroma-client-" + tag + "-" + sanitize(suffix)
}

///|
/// Replaces anything Chroma would reject in a collection name with `-`.
fn sanitize(value : String) -> String {
  let out = StringBuilder()
  for c in value {
    match c {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' => out.write_char(c)
      _ => out.write_char('-')
    }
  }
  out.to_string()
}

///|
/// Creates a collection for one test and deletes it afterwards.
async fn with_collection(
  tag : String,
  body : async (ChromaClient[AsyncHttpTransport], Collection) -> Unit,
) -> Unit {
  let client = live_client()
  let name = unique_name(tag)
  // A leftover collection from an interrupted run would make the test
  // order-dependent, so start from a known-clean slate.
  client.delete_collection_async(name) catch {
    _ => ()
  }
  let collection = client.create_collection_async(name)
  // Cleanup must run even when the body raises, otherwise a failing test
  // leaves a collection behind and the next run sees a different server.
  defer (client.delete_collection_async(name) catch { _ => () })
  body(client, collection)
}
