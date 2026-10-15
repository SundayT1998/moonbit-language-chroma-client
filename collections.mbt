///|
/// Lists every collection in the configured tenant and database.
pub fn[T : @http.Transport] ChromaClient::list_collections(
  self : ChromaClient[T],
) -> Array[Collection] raise ChromaError {
  let response = self.send_json(
    @http.Get,
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
pub fn[T : @http.Transport] ChromaClient::count_collections(
  self : ChromaClient[T],
) -> Int32 raise ChromaError {
  let response = self.send_json(
    @http.Get,
    self.database_prefix() + "/collections_count",
  )
  required_int(response, "count")
}

///|
/// Returns a collection handle for `name`, creating it if it does not exist.
///
/// This is the usual entry point: Chroma resolves the embedding function
/// server-side, so the client never needs to embed text itself.
pub fn[T : @http.Transport] ChromaClient::get_or_create_collection(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json(@http.Post, path, body=create_body(name, config)),
  )
}

///|
/// Returns a collection handle for `name`, creating it only when missing.
///
/// Mirrors Chroma's `get_or_create` behaviour but via the dedicated
/// endpoint so the server can report a conflict when the collection exists
/// with a different configuration.
pub fn[T : @http.Transport] ChromaClient::create_collection(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json(@http.Post, path, body=create_body(name, config)),
  )
}

///|
/// Fetches an existing collection by name, returning `None` on 404.
pub fn[T : @http.Transport] ChromaClient::get_collection(
  self : ChromaClient[T],
  name : String,
) -> Collection? raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    @http.encode_path_segment(name)
  let response = self.send_json(@http.Get, path) catch {
    ChromaError::Status(404, _) => return None
    error => raise error
  }
  Some(Collection::from_json(response))
}

///|
/// Deletes a collection by name.
pub fn[T : @http.Transport] ChromaClient::delete_collection(
  self : ChromaClient[T],
  name : String,
) -> Unit raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    @http.encode_path_segment(name)
  ignore(self.send_json(@http.Delete, path))
}

///|
/// Updates a collection's name and/or metadata.
///
/// `new_name` of `None` keeps the current name.
pub fn[T : @http.Transport] ChromaClient::modify_collection(
  self : ChromaClient[T],
  name : String,
  new_name~ : String? = None,
  metadata~ : Metadata? = None,
) -> Unit raise ChromaError {
  let body : Map[String, Json] = Map([])
  match new_name {
    Some(value) => body["new_name"] = Json::string(value)
    None => ()
  }
  match metadata {
    Some(value) => body["metadata"] = metadata_to_json(value)
    None => ()
  }
  let path = self.database_prefix() +
    "/collections/" +
    @http.encode_path_segment(name)
  ignore(self.send_json(@http.Put, path, body=Json::object(body)))
}
