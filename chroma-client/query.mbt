///|
/// How a query should return embeddings, documents and metadata.
///
/// Chroma only honours `include` on query/get endpoints, and uploading
/// `embeddings` is usually what you want to skip on large collections.
pub(all) struct Include {
  documents : Bool
  embeddings : Bool
  metadatas : Bool
  distances : Bool
} derive(Eq, Debug)

///|
/// Default include set: documents, metadata and distances, no vectors.
pub fn Include::default() -> Include {
  { documents: true, embeddings: false, metadatas: true, distances: true, }
}

///|
/// Every field, including embeddings.
pub fn Include::all() -> Include {
  { documents: true, embeddings: true, metadatas: true, distances: true, }
}

///|
/// Only ids.
pub fn Include::ids_only() -> Include {
  { documents: false, embeddings: false, metadatas: false, distances: false, }
}

///|
/// Renders the include set as the JSON array Chroma expects.
fn Include::to_json(self : Include) -> Json {
  let items : Array[Json] = []
  if self.documents {
    items.push(Json::string("documents"))
  }
  if self.embeddings {
    items.push(Json::string("embeddings"))
  }
  if self.metadatas {
    items.push(Json::string("metadatas"))
  }
  if self.distances {
    items.push(Json::string("distances"))
  }
  Json::array(items)
}

///|
/// Reads a `QueryResult` from a query/get response.
///
/// Query responses nest the result arrays one level deeper than get
/// responses (one entry per query embedding), so `unwrap_first` flattens
/// the common single-query case.
pub fn QueryResult::from_json(json : Json) -> QueryResult {
  let ids = string_array(optional_array(json, "ids"))
  let documents = optional_string_array(optional_array(json, "documents"))
  let metadatas = metadata_array(optional_array(json, "metadatas"))
  let distances = optional_number_array(optional_array(json, "distances"))
  let embeddings = embedding_array(optional_array(json, "embeddings"))
  { ids, documents, embeddings, metadatas, distances, }
}

///|
/// Reads a query response, where each field is an array with one entry per
/// query embedding. Returns the result for the first embedding.
pub fn QueryResult::from_query_json(json : Json) -> QueryResult {
  let ids = string_array(first_row(optional_array(json, "ids")))
  let documents = optional_string_array(
    first_row(optional_array(json, "documents")),
  )
  let metadatas = metadata_array(first_row(optional_array(json, "metadatas")))
  let distances = optional_number_array(
    first_row(optional_array(json, "distances")),
  )
  let embeddings = embedding_array(
    first_row(optional_array(json, "embeddings")),
  )
  { ids, documents, embeddings, metadatas, distances, }
}

///|
/// Unwraps the per-query nesting, returning `[]` when the response is empty.
fn first_row(value : Array[Json]) -> Array[Json] {
  if value.length() == 0 {
    []
  } else {
    match value[0] {
      Json::Array(items) => items
      _ => []
    }
  }
}

///|
fn string_array(values : Array[Json]) -> Array[String] {
  let out : Array[String] = []
  for value in values {
    match value {
      Json::String(s) => out.push(s)
      _ => ()
    }
  }
  out
}

///|
fn optional_string_array(values : Array[Json]) -> Array[String?] {
  let out : Array[String?] = []
  for value in values {
    match value {
      Json::String(s) => out.push(Some(s))
      _ => out.push(None)
    }
  }
  out
}

///|
fn optional_number_array(values : Array[Json]) -> Array[Double?] {
  let out : Array[Double?] = []
  for value in values {
    match value {
      Json::Number(n, ..) => out.push(Some(n))
      _ => out.push(None)
    }
  }
  out
}

///|
fn metadata_array(values : Array[Json]) -> Array[Metadata] {
  let out : Array[Metadata] = []
  for value in values {
    out.push(metadata_from_json(value))
  }
  out
}

///|
fn embedding_array(values : Array[Json]) -> Array[Embedding?] {
  let out : Array[Embedding?] = []
  for value in values {
    match value {
      Json::Array(items) => {
        let decoded : Embedding = []
        for item in items {
          match item {
            Json::Number(n, ..) => decoded.push(n)
            _ => ()
          }
        }
        out.push(Some(decoded))
      }
      _ => out.push(None)
    }
  }
  out
}

///|
/// Searches a collection by text, letting the server embed the queries.
pub fn[T : @http.Transport] ChromaClient::query_text(
  self : ChromaClient[T],
  collection_id : String,
  texts : Array[String],
  n_results~ : Int32 = 10,
  include_fields~ : Include = Include::default(),
) -> QueryResult raise ChromaError {
  let items : Array[Json] = []
  for text in texts {
    items.push(Json::string(text))
  }
  let body : Map[String, Json] = Map([])
  body["query_texts"] = Json::array(items)
  body["n_results"] = Json::number(n_results.to_double())
  body["include"] = include_fields.to_json()
  self.run_query(collection_id, Json::object(body))
}

///|
/// Searches a collection with caller-supplied query vectors.
pub fn[T : @http.Transport] ChromaClient::query_embeddings(
  self : ChromaClient[T],
  collection_id : String,
  embeddings : Array[Embedding],
  n_results~ : Int32 = 10,
  include_fields~ : Include = Include::default(),
) -> QueryResult raise ChromaError {
  let items : Array[Json] = []
  for embedding in embeddings {
    items.push(embedding_to_json(embedding))
  }
  let body : Map[String, Json] = Map([])
  body["query_embeddings"] = Json::array(items)
  body["n_results"] = Json::number(n_results.to_double())
  body["include"] = include_fields.to_json()
  self.run_query(collection_id, Json::object(body))
}

///|
/// Posts a query body and decodes the nested query response.
fn[T : @http.Transport] ChromaClient::run_query(
  self : ChromaClient[T],
  collection_id : String,
  body : Json,
) -> QueryResult raise ChromaError {
  let path = self.collection_path(collection_id) + "/query"
  QueryResult::from_query_json(self.send_json(@http.Post, path, body~))
}

///|
pub extend Include with Eq::{not_equal, equal}

///|
pub extend Include with @debug.Debug::{to_repr}
