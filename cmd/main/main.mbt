///|
/// A runnable demo that shows how to drive the client.
///
/// The library never performs I/O itself, so this demo uses a transport
/// that prints each request instead of sending it. Swap in your own
/// `@chroma.Transport` to talk to a real server.
///
/// Usage: `moon run cmd/main -- <collection-name>`
fn main raise {
  let name = collection_name()
  let client = @chroma.ChromaClient::new(DemoTransport::new())
  println("Chroma endpoint: " + client.config().endpoint)
  println("Collection: " + name)
  let configuration = @chroma.CollectionConfig::new(metadata=[
    ("example", @chroma.MString("moonbit")),
  ])
  println(
    "Create payload:\n" +
    @chroma.debug_collection_config(configuration).stringify(indent=2) +
    "\n",
  )
  let transport = @chroma.memory_transport(responses=[
    @chroma.json_response(200, "{\"id\":\"c1\",\"name\":\"demo\"}"),
  ])
  let scripted = @chroma.ChromaClient::new(transport)
  let collection = scripted.create_collection(name, config=configuration)
  println("Created collection " + collection.id + " (" + collection.name + ")")
}

///|
/// Reads the collection name from the command line.
fn collection_name() -> String {
  let args = @env.args()
  if args.length() > 1 {
    args[1]
  } else {
    "demo"
  }
}

///|
/// A transport that logs requests and returns an empty object, so the demo
/// runs without a live Chroma server.
struct DemoTransport {
  label : String
}

///|
fn DemoTransport::new() -> DemoTransport {
  { label: "demo", }
}

///|
impl @chroma.Transport for DemoTransport with fn send(self, request) {
  println(
    "[" + self.label + "] " + request.verb.to_string() + " " + request.url,
  )
  match request.body {
    Some(body) => println("  body: " + body)
    None => ()
  }
  @chroma.json_response(200, "{}")
}

///|
pub extend DemoTransport with @chroma.Transport::{send}
