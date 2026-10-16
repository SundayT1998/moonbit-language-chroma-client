///|
/// A record stored in a collection.
///
/// `embedding` is `None` for records whose vectors are produced by the
/// server-side embedding function.
pub(all) struct Record {
  id : String
  document : String?
  embedding : Embedding?
  metadata : Metadata
  embedding_function : Json?
} derive(Eq, Debug)

///|
/// Builds a document record that the server will embed.
pub fn Record::of_document(
  id : String,
  document : String,
  metadata~ : Metadata = [],
) -> Record {
  {
    id,
    document: Some(document),
    embedding: None,
    metadata,
    embedding_function: None,
  }
}

///|
/// Builds a record with a caller-supplied embedding.
pub fn Record::of_embedding(
  id : String,
  embedding : Embedding,
  metadata~ : Metadata = [],
) -> Record {
  {
    id,
    document: None,
    embedding: Some(embedding),
    metadata,
    embedding_function: None,
  }
}

///|
/// Returns a copy of the record that pins the embedding function it should
/// be embedded with.
///
/// Chroma v2 accepts a per-record `embedding_function` override on
/// `add`/`upsert`, but only when the record carries a `document`: with a
/// caller-supplied `embedding` there is nothing left to embed, and the
/// server answers 422. This client therefore refuses the combination up
/// front instead of emitting a request that cannot succeed.
///
/// Overriding per record is only worth it when one collection holds
/// documents written with different functions; when every record shares a
/// function, set it once on the collection via `CollectionConfig`.
pub fn Record::with_embedding_function(
  self : Record,
  config : Json,
) -> Record raise ChromaError {
  match self.document {
    Some(_) => { ..self, embedding_function: Some(config), }
    None =>
      raise ChromaError::InvalidArgument(
        "record " +
        self.id +
        " has no document, so an embedding_function override has nothing to embed",
      )
  }
}

///|
/// Serializes a record into the add/upsert wire format.
pub fn Record::to_json(self : Record) -> Json {
  let body : Map[String, Json] = Map([])
  body["id"] = Json::string(self.id)
  match self.document {
    Some(document) => body["document"] = Json::string(document)
    None => ()
  }
  match self.embedding {
    Some(embedding) => body["embedding"] = embedding_to_json(embedding)
    None => ()
  }
  if self.metadata.length() > 0 {
    body["metadata"] = metadata_to_json(self.metadata)
  }
  match self.embedding_function {
    Some(config) => body["embedding_function"] = config
    None => ()
  }
  Json::object(body)
}

///|
/// A row returned by `get` or `query`.
pub(all) struct QueryResult {
  ids : Array[String]
  documents : Array[String?]
  embeddings : Array[Embedding?]
  metadatas : Array[Metadata]
  distances : Array[Double?]
} derive(Eq, Debug)

///|
/// Where-clause filters for `get`, `update` and `delete`.
///
/// These mirror Chroma's `where` / `where_document` JSON filters.
pub(all) struct Filter {
  where_clause : Json?
  where_document_clause : Json?
  ids : Array[String]
  limit : Int32?
  offset : Int32?
} derive(Eq, Debug)

///|
/// Builds an empty filter that matches everything.
pub fn Filter::new(
  where_clause~ : Json? = None,
  where_document_clause~ : Json? = None,
  ids~ : Array[String] = [],
  limit~ : Int32? = None,
  offset~ : Int32? = None,
) -> Filter {
  { where_clause, where_document_clause, ids, limit, offset, }
}

///|
/// Adds a metadata equality condition to the filter.
pub fn Filter::with_metadata(
  self : Filter,
  key : String,
  value : MetadataValue,
) -> Filter {
  let inner : Map[String, Json] = Map([])
  inner["$eq"] = value.to_json()
  let outer : Map[String, Json] = Map([])
  outer[key] = Json::object(inner)
  let clause = Json::object(outer)
  { ..self, where_clause: Some(clause), }
}

///|
/// Adds a limit to the filter.
pub fn Filter::with_limit(self : Filter, limit : Int32) -> Filter {
  { ..self, limit: Some(limit), }
}

///|
/// Serializes the filter fields that are shared by get/update/delete.
fn Filter::to_json(self : Filter) -> Json {
  let body : Map[String, Json] = Map([])
  match self.where_clause {
    Some(value) => body["where"] = value
    None => ()
  }
  match self.where_document_clause {
    Some(value) => body["where_document"] = value
    None => ()
  }
  if self.ids.length() > 0 {
    let ids : Array[Json] = []
    for id in self.ids {
      ids.push(Json::string(id))
    }
    body["ids"] = Json::array(ids)
  }
  match self.limit {
    Some(value) => body["limit"] = Json::number(value.to_double())
    None => ()
  }
  match self.offset {
    Some(value) => body["offset"] = Json::number(value.to_double())
    None => ()
  }
  Json::object(body)
}

///|
/// Adds records to a collection.
///
/// Every record must carry either a `document` or an `embedding`, otherwise
/// Chroma rejects the request.
pub fn[T : @http.Transport] ChromaClient::add(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
) -> Unit raise ChromaError {
  validate_records(records)
  let items : Array[Json] = []
  for record in records {
    items.push(record.to_json())
  }
  let body = Json::object({ "records": Json::array(items) })
  let path = self.collection_path(collection_id) + "/add"
  ignore(self.send_json(@http.Post, path, body~))
}

///|
/// Inserts or replaces records by id.
pub fn[T : @http.Transport] ChromaClient::upsert(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
) -> Unit raise ChromaError {
  validate_records(records)
  let items : Array[Json] = []
  for record in records {
    items.push(record.to_json())
  }
  let body = Json::object({ "records": Json::array(items) })
  let path = self.collection_path(collection_id) + "/upsert"
  ignore(self.send_json(@http.Post, path, body~))
}

///|
/// Updates the document, metadata or embedding of existing records.
///
/// Records are matched by id; ids that do not exist are ignored by Chroma.
pub fn[T : @http.Transport] ChromaClient::update(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
  filter~ : Filter = Filter::new(),
) -> Unit raise ChromaError {
  validate_records(records)
  let items : Array[Json] = []
  for record in records {
    items.push(record.to_json())
  }
  let body : Map[String, Json] = Map([])
  body["records"] = Json::array(items)
  match filter.where_clause {
    Some(value) => body["where"] = value
    None => ()
  }
  match filter.where_document_clause {
    Some(value) => body["where_document"] = value
    None => ()
  }
  let path = self.collection_path(collection_id) + "/update"
  ignore(self.send_json(@http.Post, path, body=Json::object(body)))
}

///|
/// Deletes records matching the filter. With an empty filter Chroma
/// deletes every record in the collection.
pub fn[T : @http.Transport] ChromaClient::delete(
  self : ChromaClient[T],
  collection_id : String,
  filter~ : Filter = Filter::new(),
) -> Unit raise ChromaError {
  let body : Map[String, Json] = Map([])
  match filter.where_clause {
    Some(value) => body["where"] = value
    None => ()
  }
  match filter.where_document_clause {
    Some(value) => body["where_document"] = value
    None => ()
  }
  if filter.ids.length() > 0 {
    let ids : Array[Json] = []
    for id in filter.ids {
      ids.push(Json::string(id))
    }
    body["ids"] = Json::array(ids)
  }
  let path = self.collection_path(collection_id) + "/delete"
  ignore(self.send_json(@http.Post, path, body=Json::object(body)))
}

///|
/// Fetches records by filter, or the whole collection when the filter is
/// empty.
pub fn[T : @http.Transport] ChromaClient::get(
  self : ChromaClient[T],
  collection_id : String,
  filter~ : Filter = Filter::new(),
) -> QueryResult raise ChromaError {
  validate_limit_offset(filter.limit, filter.offset)
  let body = filter.to_json()
  let path = self.collection_path(collection_id) + "/get"
  QueryResult::from_json(self.send_json(@http.Post, path, body~))
}

///|
pub extend Record with Eq::{not_equal, equal}

///|
pub extend Record with @debug.Debug::{to_repr}

///|
pub extend QueryResult with Eq::{not_equal, equal}

///|
pub extend QueryResult with @debug.Debug::{to_repr}

///|
pub extend Filter with Eq::{not_equal, equal}

///|
pub extend Filter with @debug.Debug::{to_repr}

///|
/// Rejects record batches Chroma would refuse, before a request is built.
///
/// Chroma answers 400 for an empty batch, a blank id, and for a record that
/// carries neither a document nor an embedding. All three are local mistakes
/// with local fixes, so they are caught here instead of after a round-trip.
pub fn validate_records(records : Array[Record]) -> Unit raise ChromaError {
  if records.length() == 0 {
    raise ChromaError::InvalidArgument(
      "records must not be empty; Chroma rejects a batch with no records",
    )
  }
  let mut index = 0
  for record in records {
    if record.id == "" {
      raise ChromaError::InvalidArgument(
        "record at index " + index.to_string() + " has an empty id",
      )
    }
    if record.document is None && record.embedding is None {
      raise ChromaError::InvalidArgument(
        "record " +
        record.id +
        " has neither a document nor an embedding; Chroma cannot store it",
      )
    }
    index = index + 1
  }
}

///|
/// Rejects a query whose inputs would be refused server-side.
///
/// `label` names the field in the error message so a caller passing both
/// texts and vectors can tell which one was empty.
pub fn validate_query_inputs(
  label : String,
  inputs : Array[Json],
) -> Unit raise ChromaError {
  if inputs.length() == 0 {
    raise ChromaError::InvalidArgument(
      label + " must not be empty; a query needs at least one input",
    )
  }
}
