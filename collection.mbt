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
/// Parameters for `get_or_create_collection` and `create_collection`.
///
/// `configuration` is sent verbatim, so index options the server knows about
/// (for example `{"hnsw": {"space": "cosine"}}`) can be set without waiting
/// for this client to model them. When it is unset a default L2 HNSW
/// configuration is sent.
pub(all) struct CollectionConfig {
  metadata : Metadata
  configuration : Json?
} derive(Eq, Debug)

///|
/// Builds a `CollectionConfig` with all options unset.
pub fn CollectionConfig::new(
  metadata~ : Metadata = [],
  configuration~ : Json? = None,
) -> CollectionConfig {
  { metadata, configuration, }
}

///|
/// Builds the request body for creating a collection.
///
/// Chroma's `CreateCollection` model takes `name`, `configuration`,
/// `metadata` and `get_or_create`. There is no top-level
/// `embedding_function` field: a collection's embedding function is
/// configured through `configuration`, so `CollectionConfig`'s name is not
/// sent on its own.
fn create_body(
  name : String,
  config : CollectionConfig,
  get_or_create~ : Bool,
) -> Json {
  let body : Map[String, Json] = Map([])
  body["name"] = Json::string(name)
  body["get_or_create"] = Json::boolean(get_or_create)
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
///
/// Same value as `CollectionConfig::to_json`; the name is kept because the
/// logging use case reads better with it.
pub fn debug_collection_config(config : CollectionConfig) -> Json {
  config.to_json()
}

///|
/// Serializes the collection configuration for a create request.
///
/// This is the body `create_collection` sends, with `get_or_create` set to
/// `false`.
pub fn CollectionConfig::to_json(config : CollectionConfig) -> Json {
  create_body("", config, get_or_create=false)
}
