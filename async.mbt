///|
/// The asynchronous half of the client.
///
/// Every public method has an `_async` twin here. The bodies are the same
/// request-building and decoding code as the synchronous versions; only the
/// hop through the transport changes. Keeping the two side by side rather
/// than sharing a generic core is deliberate: MoonBit cannot abstract over
/// "sync or async" without making the synchronous API pay for a future it
/// never uses, and the request construction is short enough that duplicating
/// the call sites is cheaper to read than a stack of higher-order helpers.
///
/// Use these with `AsyncTransport` (native and wasm); use the
/// synchronous methods with `Transport` (tests, and any host that
/// already drives its own I/O).

///|
/// Sends a request through an async transport.
///
/// Mirrors `ChromaClient::send`, including the pass-through of errors an
/// inner transport already classified.
async fn[T : AsyncTransport] ChromaClient::send_async(
  self : ChromaClient[T],
  verb : Method,
  path : String,
  body~ : Json = Json::null(),
) -> Response raise ChromaError {
  let headers : Map[String, String] = { "content-type": "application/json" }
  for entry in self.config.headers {
    let (key, value) = entry
    headers[key] = value
  }
  let payload = match verb {
    Get | Delete => None
    _ => Some(body.stringify())
  }
  let request : Request = {
    verb,
    url: self.api_url(path),
    headers,
    body: payload,
  }
  let response = self.transport.send_async(request) catch {
    ChromaError::Api(_) as error => raise error
    ChromaError::Status(_, _) as error => raise error
    ChromaError::Decode(_) as error => raise error
    ChromaError::InvalidArgument(_) as error => raise error
    ChromaError::Transport(_) as error => raise error
    error => raise ChromaError::Transport(error.to_string())
  }
  if response.status < 200 || response.status >= 300 {
    raise api_error(response.status, response.body)
  }
  guard_response_body(response)
  response
}

///|
/// Sends a request and parses the response body as JSON.
async fn[T : AsyncTransport] ChromaClient::send_json_async(
  self : ChromaClient[T],
  verb : Method,
  path : String,
  body~ : Json = Json::null(),
) -> Json raise ChromaError {
  self.response_json_or_null(self.send_async(verb, path, body~))
}

///|
/// Checks that the server is reachable and returns its heartbeat timestamp.
pub async fn[T : AsyncTransport] ChromaClient::heartbeat_async(
  self : ChromaClient[T],
) -> Int64 raise ChromaError {
  self.heartbeat_value(self.send_json_async(Get, "heartbeat"))
}

///|
/// Returns the server version string.
pub async fn[T : AsyncTransport] ChromaClient::version_async(
  self : ChromaClient[T],
) -> String raise ChromaError {
  match self.send_json_async(Get, "version") {
    Json::String(s) => s
    _ => ""
  }
}

///|
/// Lists every collection in the configured tenant and database.
pub async fn[T : AsyncTransport] ChromaClient::list_collections_async(
  self : ChromaClient[T],
) -> Array[Collection] raise ChromaError {
  let response = self.send_json_async(
    Get,
    self.database_prefix() + "/collections",
  )
  let items = match response {
    Json::Array(items) => items
    _ => raise ChromaError::Decode("expected an array of collections")
  }
  let out : Array[Collection] = []
  for item in items {
    out.push(Collection::from_json(item))
  }
  out
}

///|
/// Counts the collections in the configured tenant and database.
pub async fn[T : AsyncTransport] ChromaClient::count_collections_async(
  self : ChromaClient[T],
) -> Int32 raise ChromaError {
  let response = self.send_json_async(
    Get,
    self.database_prefix() + "/collections_count",
  )
  decode_count(response, "collections_count")
}

///|
/// Returns a collection handle for `name`, creating it when it is missing.
pub async fn[T : AsyncTransport] ChromaClient::get_or_create_collection_async(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json_async(
      Post,
      path,
      body=create_body(name, config, get_or_create=true),
    ),
  )
}

///|
/// Creates a collection, failing when `name` is already taken.
pub async fn[T : AsyncTransport] ChromaClient::create_collection_async(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json_async(
      Post,
      path,
      body=create_body(name, config, get_or_create=false),
    ),
  )
}

///|
/// Fetches an existing collection by name, returning `None` on 404.
pub async fn[T : AsyncTransport] ChromaClient::get_collection_async(
  self : ChromaClient[T],
  name : String,
) -> Collection? raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    encode_path_segment(name)
  let response = self.send_json_async(Get, path) catch {
    error =>
      if error.status_code() == Some(404) {
        return None
      } else {
        raise error
      }
  }
  Some(Collection::from_json(response))
}

///|
/// Deletes a collection by name.
pub async fn[T : AsyncTransport] ChromaClient::delete_collection_async(
  self : ChromaClient[T],
  name : String,
) -> Unit raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    encode_path_segment(name)
  ignore(self.send_json_async(Delete, path))
}

///|
/// Counts the records in a collection.
pub async fn[T : AsyncTransport] ChromaClient::count_async(
  self : ChromaClient[T],
  collection_id : String,
) -> Int32 raise ChromaError {
  let path = self.collection_path(collection_id) + "/count"
  decode_count(self.send_json_async(Get, path), "collections/{id}/count")
}

///|
/// Adds records to a collection.
pub async fn[T : AsyncTransport] ChromaClient::add_async(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
) -> Unit raise ChromaError {
  validate_records(records)
  let path = self.collection_path(collection_id) + "/add"
  ignore(self.send_json_async(Post, path, body=records_to_columns(records)))
}

///|
/// Inserts or replaces records by id.
pub async fn[T : AsyncTransport] ChromaClient::upsert_async(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
) -> Unit raise ChromaError {
  validate_records(records)
  let path = self.collection_path(collection_id) + "/upsert"
  ignore(self.send_json_async(Post, path, body=records_to_columns(records)))
}

///|
/// Updates the document, metadata or embedding of existing records.
///
/// Records are matched by id; ids that do not exist are ignored by Chroma.
pub async fn[T : AsyncTransport] ChromaClient::update_async(
  self : ChromaClient[T],
  collection_id : String,
  records : Array[Record],
  filter~ : Filter = Filter::new(),
) -> Unit raise ChromaError {
  // An update patches the records it names, so a missing embedding or
  // document is the normal case rather than an error: a `null` column entry
  // tells Chroma to leave that field alone.
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
  ignore(self.send_json_async(Post, path, body=Json::object(body)))
}

///|
/// Deletes records matching the filter.
pub async fn[T : AsyncTransport] ChromaClient::delete_async(
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
  ignore(self.send_json_async(Post, path, body=Json::object(body)))
}

///|
/// Fetches records by filter, or the whole collection when the filter is
/// empty.
pub async fn[T : AsyncTransport] ChromaClient::get_async(
  self : ChromaClient[T],
  collection_id : String,
  filter~ : Filter = Filter::new(),
) -> QueryResult raise ChromaError {
  validate_limit_offset(filter.limit, filter.offset)
  let path = self.collection_path(collection_id) + "/get"
  QueryResult::from_json(
    self.send_json_async(Post, path, body=filter.to_json()),
  )
}

///|
/// Searches a collection with caller-supplied query vectors.
pub async fn[T : AsyncTransport] ChromaClient::query_embeddings_async(
  self : ChromaClient[T],
  collection_id : String,
  embeddings : Array[Embedding],
  n_results~ : Int32 = 10,
  include_fields~ : Include = Include::default(),
  filter~ : Filter = Filter::new(),
) -> QueryResult raise ChromaError {
  validate_n_results(n_results)
  validate_limit_offset(filter.limit, filter.offset)
  let items : Array[Json] = []
  for embedding in embeddings {
    items.push(embedding_to_json(embedding))
  }
  validate_query_inputs("query_embeddings", items)
  let body : Map[String, Json] = Map([])
  body["query_embeddings"] = Json::array(items)
  body["n_results"] = Json::number(n_results.to_double())
  body["include"] = include_fields.to_json()
  append_filter(body, filter)
  let path = self.collection_path(collection_id) + "/query"
  let response = self.send_async(Post, path, body=Json::object(body))
  QueryResult::from_query_json(self.response_json_or_null(response))
}

///|
/// Returns a small sample of the records in a collection.
///
/// `limit` is capped at `peek_limit` so a stray large value cannot turn a
/// preview into a full scan of the collection.
pub async fn[T : AsyncTransport] ChromaClient::peek_async(
  self : ChromaClient[T],
  collection_id : String,
  limit~ : Int32 = 10,
  include_fields~ : Include = Include::default(),
) -> QueryResult raise ChromaError {
  let limit = clamp_peek_limit(limit)
  let body : Map[String, Json] = Map([])
  body["limit"] = Json::number(limit.to_double())
  body["include"] = include_fields.to_json()
  let path = self.collection_path(collection_id) + "/get"
  QueryResult::from_json(
    self.send_json_async(Post, path, body=Json::object(body)),
  )
}

///|
/// Updates a collection's name and/or metadata.
///
/// `new_name` of `None` keeps the current name. `name` may be the collection's
/// name or its id; a name is looked up first, because the server's `PUT`
/// endpoint only accepts an id (see `resolve_collection_id`).
pub async fn[T : AsyncTransport] ChromaClient::modify_collection_async(
  self : ChromaClient[T],
  name : String,
  new_name~ : String? = None,
  metadata~ : Metadata? = None,
) -> Unit raise ChromaError {
  let body = modify_body(new_name, metadata)
  let id = self.resolve_collection_id_async(name)
  let path = self.database_prefix() + "/collections/" + encode_path_segment(id)
  ignore(self.send_json_async(Put, path, body=Json::object(body)))
}

///|
/// The async counterpart of `resolve_collection_id`.
async fn[T : AsyncTransport] ChromaClient::resolve_collection_id_async(
  self : ChromaClient[T],
  name_or_id : String,
) -> String raise ChromaError {
  if is_uuid_v4(name_or_id) {
    return name_or_id
  }
  match self.get_collection_async(name_or_id) {
    Some(collection) => collection.id
    None =>
      raise ChromaError::InvalidArgument("no such collection: " + name_or_id)
  }
}
