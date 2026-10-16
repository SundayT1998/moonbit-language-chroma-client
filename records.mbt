///|
/// A record stored in a collection.
///
/// `embedding` is `None` for a record that carries only a document. Chroma
/// needs a vector for every record, so a batch with a missing embedding is
/// rejected locally instead of by the server (see `validate_records`).
pub(all) struct Record {
  id : String
  document : String?
  embedding : Embedding?
  metadata : Metadata
} derive(Eq, Debug)

///|
/// Builds a record that carries a document and no embedding.
///
/// Chroma 1.x has no server-side embedding, so a record built this way can
/// only be stored once an `embedding` is attached via `Record::with_embedding`.
pub fn Record::of_document(
  id : String,
  document : String,
  metadata~ : Metadata = [],
) -> Record {
  { id, document: Some(document), embedding: None, metadata, }
}

///|
/// Builds a record with a caller-supplied embedding.
pub fn Record::of_embedding(
  id : String,
  embedding : Embedding,
  metadata~ : Metadata = [],
) -> Record {
  { id, document: None, embedding: Some(embedding), metadata, }
}

///|
/// Returns a copy of the record with `embedding` attached.
///
/// Use it to add a vector to a record built by `Record::of_document`; a
/// record with explicit coordinates is built with `Record::of_embedding`.
pub fn Record::with_embedding(self : Record, embedding : Embedding) -> Record {
  { ..self, embedding: Some(embedding), }
}

///|
/// Returns a copy of the record carrying `document` as well.
///
/// Pairs with `Record::of_embedding` when the vector is known first and the
/// text it stands for second.
pub fn Record::with_document(self : Record, document : String) -> Record {
  { ..self, document: Some(document), }
}

///|
/// Returns a copy of the record carrying `metadata` instead of its own.
pub fn Record::with_metadata(self : Record, metadata : Metadata) -> Record {
  { ..self, metadata, }
}

///|
/// Serializes a batch of records into the columnar body Chroma expects.
///
/// Chroma does not take records one by one: the add/upsert/update models are
/// parallel arrays (`ids`, `embeddings`, `documents`, `metadatas`) that must
/// be the same length and aligned by index. A column is emitted only when it
/// carries data, and a `null` marks a record that has no value for it — that
/// position-preserving `null` is what keeps the arrays aligned.
///
/// `embeddings` is the exception: Chroma requires the field and rejects a
/// batch where it is missing, null or empty, so a record without coordinates
/// has no representation here. `validate_records` refuses such a batch
/// before it is serialized.
pub fn records_to_columns(records : Array[Record]) -> Json {
  let ids : Array[Json] = []
  let embeddings : Array[Json] = []
  let documents : Array[Json] = []
  let metadatas : Array[Json] = []
  let mut has_documents = false
  let mut has_metadatas = false
  for record in records {
    ids.push(Json::string(record.id))
    embeddings.push(
      match record.embedding {
        Some(embedding) => embedding_to_json(embedding)
        None => Json::null()
      },
    )
    match record.document {
      Some(document) => {
        has_documents = true
        documents.push(Json::string(document))
      }
      None => documents.push(Json::null())
    }
    if record.metadata.length() > 0 {
      has_metadatas = true
      metadatas.push(metadata_to_json(record.metadata))
    } else {
      metadatas.push(Json::null())
    }
  }
  let body : Map[String, Json] = Map([])
  body["ids"] = Json::array(ids)
  body["embeddings"] = Json::array(embeddings)
  if has_documents {
    body["documents"] = Json::array(documents)
  }
  if has_metadatas {
    body["metadatas"] = Json::array(metadatas)
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
  let path = self.collection_path(collection_id) + "/add"
  ignore(self.send_json(@http.Post, path, body=records_to_columns(records)))
}

///|
/// Inserts or replaces records by id.
pub fn[T : @http.Transport] ChromaClient::upsert(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
) -> Unit raise ChromaError {
  validate_records(records)
  let path = self.collection_path(collection_id) + "/upsert"
  ignore(self.send_json(@http.Post, path, body=records_to_columns(records)))
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
  // An update patches the records it names, so a missing embedding or
  // document is the normal case rather than an error. Chroma's update model
  // accepts `null` in a column to mean "leave this field alone", which is
  // exactly what `records_to_columns` emits.
  validate_records(records, require_embedding=false)
  let body : Map[String, Json] = match records_to_columns(records) {
    Json::Object(fields) => fields.copy()
    _ => Map([])
  }
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
/// Chroma answers 400 for an empty batch and for a blank id, and its
/// add/upsert models make `embeddings` mandatory, so a batch whose records
/// have no vectors is refused too. All of these are local mistakes with local
/// fixes, so they are caught here instead of after a round-trip.
///
/// `require_embedding` is `false` for `update`, where omitting a field is how
/// a caller says "change only what I passed".
pub fn validate_records(
  records : Array[Record],
  require_embedding~ : Bool = true,
) -> Unit raise ChromaError {
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
    if require_embedding && record.embedding is None {
      if record.document is None {
        raise ChromaError::InvalidArgument(
          "record " +
          record.id +
          " has neither a document nor an embedding; Chroma cannot store it",
        )
      }
      raise ChromaError::InvalidArgument(
        "record " +
        record.id +
        " has a document but no embedding; Chroma 1.x does not embed documents server-side, " +
        "so attach a vector with Record::with_embedding before storing it",
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
