///|
/// Lists every collection in the configured tenant and database.
pub fn[T : Transport] ChromaClient::list_collections(
  self : ChromaClient[T],
) -> Array[Collection] raise ChromaError {
  let response = self.send_json(Get, self.database_prefix() + "/collections")
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
pub fn[T : Transport] ChromaClient::count_collections(
  self : ChromaClient[T],
) -> Int32 raise ChromaError {
  let response = self.send_json(
    Get,
    self.database_prefix() + "/collections_count",
  )
  decode_count(response, "collections_count")
}

///|
/// Returns a collection handle for `name`, creating it when it is missing.
///
/// Sends `get_or_create: true`, so calling it twice finds the collection
/// instead of colliding on the second call.
pub fn[T : Transport] ChromaClient::get_or_create_collection(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json(
      Post,
      path,
      body=create_body(name, config, get_or_create=true),
    ),
  )
}

///|
/// Creates a collection, failing when `name` is already taken.
///
/// Sends `get_or_create: false`, so the server answers 409 rather than
/// silently returning a collection that may have a different
/// configuration. Use `get_or_create_collection` when either outcome is fine.
pub fn[T : Transport] ChromaClient::create_collection(
  self : ChromaClient[T],
  name : String,
  config~ : CollectionConfig = CollectionConfig::new(),
) -> Collection raise ChromaError {
  let path = self.database_prefix() + "/collections"
  Collection::from_json(
    self.send_json(
      Post,
      path,
      body=create_body(name, config, get_or_create=false),
    ),
  )
}

///|
/// Fetches an existing collection by name, returning `None` on 404.
pub fn[T : Transport] ChromaClient::get_collection(
  self : ChromaClient[T],
  name : String,
) -> Collection? raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    encode_path_segment(name)
  let response = self.send_json(Get, path) catch {
    // The server may report the miss as a bare status or as a parsed
    // `Api` error; both mean "no such collection".
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
pub fn[T : Transport] ChromaClient::delete_collection(
  self : ChromaClient[T],
  name : String,
) -> Unit raise ChromaError {
  let path = self.database_prefix() +
    "/collections/" +
    encode_path_segment(name)
  ignore(self.send_json(Delete, path))
}

///|
/// Updates a collection's name and/or metadata.
///
/// `new_name` of `None` keeps the current name. `name` may be the collection's
/// name or its id; a name is looked up first, because the server's `PUT`
/// endpoint only accepts an id.
pub fn[T : Transport] ChromaClient::modify_collection(
  self : ChromaClient[T],
  name : String,
  new_name~ : String? = None,
  metadata~ : Metadata? = None,
) -> Unit raise ChromaError {
  let body = modify_body(new_name, metadata)
  let id = self.resolve_collection_id(name)
  let path = self.database_prefix() + "/collections/" + encode_path_segment(id)
  ignore(self.send_json(Put, path, body=Json::object(body)))
}

///|
/// Builds the `UpdateCollection` body, including only the fields given.
///
/// Chroma's model names the metadata field `new_metadata`;
/// sending `metadata` is silently ignored by the server.
fn modify_body(new_name : String?, metadata : Metadata?) -> Map[String, Json] {
  let body : Map[String, Json] = Map([])
  match new_name {
    Some(value) => body["new_name"] = Json::string(value)
    None => ()
  }
  match metadata {
    Some(value) => body["new_metadata"] = metadata_to_json(value)
    None => ()
  }
  body
}

///|
/// Resolves an id-or-name argument to the collection's id.
///
/// `PUT /collections/{id}` rejects anything that is not a UUIDv4 with a 400
/// ("Collection ID is not a valid UUIDv4"), unlike the `GET`/`DELETE` routes
/// below the same path, which also accept a name. Callers pass whichever they
/// have, so a value that already looks like an id is used as-is and a name is
/// looked up through `get_collection`.
fn[T : Transport] ChromaClient::resolve_collection_id(
  self : ChromaClient[T],
  name_or_id : String,
) -> String raise ChromaError {
  if is_uuid_v4(name_or_id) {
    return name_or_id
  }
  match self.get_collection(name_or_id) {
    Some(collection) => collection.id
    None =>
      raise ChromaError::InvalidArgument("no such collection: " + name_or_id)
  }
}

///|
/// Whether `value` is a canonical UUIDv4 string.
///
/// Only the shape matters: a name can never be 36 characters of hex and
/// hyphens in the 8-4-4-4-12 layout, so this tells the two apart without a
/// round trip.
fn is_uuid_v4(value : String) -> Bool {
  if value.length() != 36 {
    return false
  }
  let chars = value.to_array()
  for i, c in chars {
    let dash = i == 8 || i == 13 || i == 18 || i == 23
    if dash {
      if c != '-' {
        return false
      }
    } else if !((c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F')) {
      return false
    }
  }
  // The version nibble of a v4 UUID is `4`; the server checks it.
  chars[14] == '4'
}

///|
/// Counts the records in a collection.
pub fn[T : Transport] ChromaClient::count(
  self : ChromaClient[T],
  collection_id : String,
) -> Int32 raise ChromaError {
  let path = self.collection_path(collection_id) + "/count"
  decode_count(self.send_json(Get, path), "collections/{id}/count")
}

///|
/// Returns a small sample of the records in a collection.
///
/// `limit` is capped at `peek_limit` so a stray large value cannot turn a
/// preview into a full scan of the collection.
pub fn[T : Transport] ChromaClient::peek(
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
  QueryResult::from_json(self.send_json(Post, path, body=Json::object(body)))
}

///|
/// The largest `limit` `peek` will send.
pub const PEEK_LIMIT : Int32 = 100

///|
/// Clamps a peek limit into `1..=PEEK_LIMIT`.
fn clamp_peek_limit(limit : Int32) -> Int32 {
  if limit < 1 {
    1
  } else if limit > PEEK_LIMIT {
    PEEK_LIMIT
  } else {
    limit
  }
}
