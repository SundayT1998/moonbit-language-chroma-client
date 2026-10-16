///|
/// A runnable walkthrough of the client against a real Chroma server.
///
/// Usage:
///
/// ```bash
/// moon run examples/native --target native -- http://localhost:8000 my-collection
/// ```
///
/// The first argument is the server endpoint (default `http://localhost:8000`),
/// the second the collection to write to (default `chroma-client-demo`). The
/// collection is deleted at the end, so the demo is repeatable.
///
/// The vectors here are written by hand rather than produced by an embedding
/// model: Chroma 1.x does not embed text server-side, and pulling in a model
/// would make this example about embeddings instead of about the client.
async fn main {
  let args = @env.args()
  let endpoint = if args.length() > 1 {
    args[1]
  } else {
    "http://localhost:8000"
  }
  let name = if args.length() > 2 { args[2] } else { "chroma-client-demo" }
  let client = @chroma.ChromaClient::new(
    AsyncHttpTransport::new(),
    config=@chroma.Config::new(endpoint~),
  )
  println("endpoint: " + endpoint)
  let heartbeat = client.heartbeat_async() catch {
    error => {
      println("cannot reach Chroma at " + endpoint + ": " + error.to_string())
      return
    }
  }
  println("heartbeat: " + heartbeat.to_string())
  println("version: " + client.version_async())
  // A leftover collection from an interrupted run would make the demo
  // order-dependent, so start from a known-clean slate.
  client.delete_collection_async(name) catch {
    // `delete_collection` on a missing name is a 404, which is exactly the
    // state we want.
    _ => ()
  }
  let collection = client.create_collection_async(name)
  println("created collection " + collection.name + " (" + collection.id + ")")
  client.add_async(collection.id, [
    @chroma.Record::of_embedding("moonbit", [1.0, 0.0, 0.0], metadata=[
      ("topic", @chroma.MString("language")),
    ]),
    @chroma.Record::of_embedding("chroma", [0.0, 1.0, 0.0], metadata=[
      ("topic", @chroma.MString("database")),
    ]),
    @chroma.Record::of_embedding("mooncake", [0.9, 0.1, 0.0], metadata=[
      ("topic", @chroma.MString("language")),
    ]),
  ])
  println("count: " + client.count_async(collection.id).to_string())
  let result = client.query_embeddings_async(
    collection.id,
    [[1.0, 0.0, 0.0]],
    n_results=2,
  )
  println("nearest neighbours of [1, 0, 0]:")
  for i, id in result.ids {
    let distance = match result.distances[i] {
      Some(value) => value.to_string()
      None => "?"
    }
    println("  " + id + "  distance=" + distance)
  }
  let filtered = client.get_async(
    collection.id,
    filter=@chroma.Filter::new().with_metadata(
      "topic",
      @chroma.MString("language"),
    ),
  )
  println("records with topic=language: " + filtered.ids.length().to_string())
  client.delete_collection_async(name)
  println("deleted collection " + name)
}
