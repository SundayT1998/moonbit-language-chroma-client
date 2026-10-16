///|
/// A Chroma collection as returned by the server.
pub(all) struct Collection {
  id : String
  name : String
  metadata : Metadata
  configuration : Json
  log_position : Int32
  version : Int32
} derive(Eq, Debug)

///|
/// Decodes a collection from a server response object.
///
/// `id` and `name` are required: a response without them is not a
/// collection, and silently defaulting a name to `""` would only push the
/// failure further down the line. The remaining fields are optional and
/// default to empty so that responses from older servers still decode.
pub fn Collection::from_json(json : Json) -> Collection raise ChromaError {
  let log_position = with_default(optional_int(json, "log_position"), 0)
  let version = with_default(optional_int(json, "version"), 0)
  {
    id: required_string(json, "id"),
    name: required_string(json, "name"),
    metadata: metadata_from_json(optional_object(json, "metadata")),
    configuration: optional_object(json, "configuration"),
    log_position,
    version,
  }
}

///|
fn with_default(value : Int32?, fallback : Int32) -> Int32 {
  match value {
    Some(v) => v
    None => fallback
  }
}

///|
/// Reads an optional integer field.
fn optional_int(json : Json, key : String) -> Int32? {
  match json {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::Number(n, ..)) => Some(n.to_int())
        _ => None
      }
    _ => None
  }
}

///|
/// Parameters for `get_or_create_collection`.
///
/// `embedding_function` is the name the *server* should use to embed
/// documents, so no embedding logic is needed on the client. Chroma's own
/// default is `default`.
pub(all) struct CollectionConfig {
  metadata : Metadata
  embedding_function : String?
  configuration : Json?
} derive(Eq, Debug)

///|
/// Builds a `CollectionConfig` with all options unset.
pub fn CollectionConfig::new(
  metadata~ : Metadata = [],
  embedding_function~ : String? = None,
  configuration~ : Json? = None,
) -> CollectionConfig {
  { metadata, embedding_function, configuration, }
}

///|
/// Serializes the collection configuration for a create/modify request.

///|
/// Builds the request body for creating a collection.
///
/// Three fields are always sent: `name`, the `configuration` that tells the
/// server which index to build, and the name of the server-side embedding
/// function to use when only documents are supplied.
fn create_body(name : String, config : CollectionConfig) -> Json {
  let body : Map[String, Json] = Map([])
  body["name"] = Json::string(name)
  let embedding_name = match config.embedding_function {
    Some(function) => function
    None => "default"
  }
  body["embedding_function"] = Json::object({
    "name": Json::string(embedding_name),
  })
  match config.configuration {
    Some(configuration) => body["configuration"] = configuration
    None => {
      let hnsw : Map[String, Json] = Map([])
      hnsw["space"] = Json::string("l2")
      body["configuration"] = Json::object({ "hnsw": Json::object(hnsw) })
    }
  }
  if config.metadata.length() > 0 {
    body["metadata"] = metadata_to_json(config.metadata)
  }
  Json::object(body)
}

///|
pub extend Collection with Eq::{not_equal, equal}

///|
pub extend Collection with @debug.Debug::{to_repr}

///|
pub extend CollectionConfig with Eq::{not_equal, equal}

///|
pub extend CollectionConfig with @debug.Debug::{to_repr}

///|
/// Serializes a collection configuration, useful for logging and for
/// building custom requests.
pub fn debug_collection_config(config : CollectionConfig) -> Json {
  create_body("", config)
}

///|
/// Serializes the collection configuration for a create/modify request.
pub fn CollectionConfig::to_json(config : CollectionConfig) -> Json {
  create_body("", config)
}
