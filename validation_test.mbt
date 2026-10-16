///|
test "add rejects an empty batch without sending anything" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => client.add("c1", []))
  match result {
    Err(InvalidArgument(message)) => assert_true(message.contains("empty"))
    _ => fail("expected an InvalidArgument error")
  }
  assert_eq(transport.observed().length(), 0)
}

///|
test "upsert rejects an empty batch" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => client.upsert("c1", []))
  assert_true(result is Err(InvalidArgument(_)))
  assert_eq(transport.observed().length(), 0)
}

///|
test "update rejects an empty batch" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => client.update("c1", []))
  assert_true(result is Err(InvalidArgument(_)))
  assert_eq(transport.observed().length(), 0)
}

///|
test "a record with neither document nor embedding is rejected locally" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let bare : @chroma-client.Record = {
    id: "r1",
    document: None,
    embedding: None,
    metadata: [],
  }
  let result = try_catch(() => client.add("c1", [bare]))
  match result {
    Err(InvalidArgument(message)) =>
      // the message names the offending record
      assert_true(message.contains("r1"))
    _ => fail("expected an InvalidArgument error")
  }
  assert_eq(transport.observed().length(), 0)
}

///|
test "an empty record id is rejected locally" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let record = @chroma-client.Record::of_document("", "hello")
  let result = try_catch(() => client.add("c1", [record]))
  assert_true(result is Err(InvalidArgument(_)))
  assert_eq(transport.observed().length(), 0)
}

///|
test "validate_records accepts a well-formed batch" {
  @chroma-client.validate_records([
    @chroma-client.Record::of_embedding("r1", [0.1]),
    @chroma-client.Record::of_embedding("r2", [0.2]),
  ]) catch {
    _ => fail("unexpected error")
  }
}

///|
test "validate_records rejects a document without an embedding" {
  let result = try_catch(() => {
    @chroma-client.validate_records([
      @chroma-client.Record::of_document("r1", "hello"),
    ])
  })
  match result {
    Err(InvalidArgument(message)) => {
      assert_true(message.contains("r1"))
      assert_true(message.contains("embedding"))
    }
    _ => fail("expected an InvalidArgument error")
  }
}

///|
test "validate_records allows a missing embedding for update" {
  // update patches by id, so a record with no vector is still meaningful:
  // it only changes the metadata of the records it names.
  let result = try_catch(() => {
    @chroma-client.validate_records(
      [
        {
          id: "r1",
          document: None,
          embedding: None,
          metadata: [("tag", MString("x"))],
        },
      ],
      require_embedding=false,
    )
  })
  match result {
    Ok(_) => ()
    Err(error) => fail("unexpected error: " + error.to_string())
  }
}

///|
test "query_embeddings rejects an empty vector list" {
  let transport = @http.MemoryTransport::new()
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.query_embeddings("c1", [])))
  match result {
    Err(InvalidArgument(message)) =>
      assert_true(message.contains("query_embeddings"))
    _ => fail("expected an InvalidArgument error")
  }
  assert_eq(transport.observed().length(), 0)
}

///|
test "a response above the size limit is reported, not truncated" {
  // one byte past the limit, built without allocating it twice
  let body = "[" + " ".repeat(@chroma-client.MAX_RESPONSE_BYTES) + "]"
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, body),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.get("c1")))
  match result {
    Err(Decode(message)) => assert_true(message.contains("byte limit"))
    _ => fail("expected a Decode error")
  }
}

///|
test "a response far below the limit still decodes" {
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(200, "{\"ids\":[\"r1\"]}"),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  assert_eq(client.get("c1").ids, ["r1"])
}

///|
test "a large error body still surfaces its message" {
  // error bodies are read before any size guard, so a long one still parses
  let padding = "x".repeat(1024)
  let body = "{\"error\":\"InternalError\",\"message\":\"" + padding + "\"}"
  let transport = @http.MemoryTransport::new(responses=[
    @http.Response::json(500, body),
  ])
  let client = @chroma-client.ChromaClient::new(transport)
  let result = try_catch(() => ignore(client.count_collections()))
  match result {
    Err(Api(error)) => {
      assert_eq(error.error_code, "InternalError")
      assert_eq(error.message.length(), 1024)
    }
    _ => fail("expected an Api error")
  }
}
