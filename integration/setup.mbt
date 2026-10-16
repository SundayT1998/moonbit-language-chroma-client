///|
/// The endpoint of the Chroma server under test, or `None` when the suite
/// should be skipped.
///
/// Integration tests only run when `CHROMA_ENDPOINT` is set. That keeps
/// `moon test` green on a laptop with no Docker daemon and on the GitHub
/// Actions matrix (macOS and Windows do not get a Chroma container), while CI
/// jobs that do start a server opt in by exporting the variable.
pub fn chroma_endpoint() -> String? {
  @env.get_env_var("CHROMA_ENDPOINT")
}

///|
/// Builds a client pointed at the server under test.
pub fn live_client() -> @chroma.ChromaClient[LiveTransport] {
  let endpoint = chroma_endpoint().unwrap()
  @chroma.ChromaClient::new(
    LiveTransport::new(),
    config=@chroma.Config::new(endpoint~),
  )
}

///|
/// A collection name that no other run can collide with.
///
/// A shared server (the CI sidecar is one) is used by parallel tests, so the
/// name carries a caller-supplied tag plus a run id. The tag keeps a failing
/// test's leftovers identifiable in `list_collections`.
pub fn unique_name(tag : String) -> String {
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
pub async fn with_collection(
  tag : String,
  body : async (@chroma.ChromaClient[LiveTransport], @chroma.Collection) -> Unit,
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
