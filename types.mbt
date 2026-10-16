///|
/// Configuration for talking to a Chroma server.
///
/// The client speaks the v2 API, so `endpoint` is normally
/// `http://localhost:8000` and the tenant/database are separate fields.
pub(all) struct Config {
  endpoint : String
  tenant : String
  database : String
  headers : Map[String, String]
  timeout_ms : Int32
} derive(Eq, Debug)

///|
/// Builds a `Config` with the Chroma defaults: `localhost:8000`,
/// tenant `default_tenant`, database `default_database`.
pub fn Config::new(
  endpoint~ : String = "http://localhost:8000",
  tenant~ : String = "default_tenant",
  database~ : String = "default_database",
  headers~ : Map[String, String] = {},
  timeout_ms~ : Int32 = 30000,
) -> Config {
  { endpoint, tenant, database, headers, timeout_ms, }
}

///|
/// Returns a copy of the configuration with a Bearer token in
/// `Authorization`.
pub fn Config::with_token(self : Config, token : String) -> Config {
  self.with_header("authorization", "Bearer " + token)
}

///|
/// Returns a copy of the configuration with HTTP Basic authentication.
pub fn Config::with_basic_auth(
  self : Config,
  username : String,
  password : String,
) -> Config {
  self.with_header(
    "authorization",
    "Basic " + @base64.encode(@utf8.encode(username + ":" + password)),
  )
}

///|
/// Returns a copy of the configuration with a merged header map, leaving
/// `self` untouched.
pub fn Config::with_headers(
  self : Config,
  headers : Map[String, String],
) -> Config {
  let merged = self.headers.copy()
  for entry in headers {
    let (key, value) = entry
    merged[key] = value
  }
  { ..self, headers: merged, }
}

///|
/// Returns a copy of the configuration with one extra header set.
pub fn Config::with_header(
  self : Config,
  name : String,
  value : String,
) -> Config {
  let headers = self.headers.copy()
  headers[name] = value
  { ..self, headers, }
}

///|
/// Metadata attached to a collection or a record.
///
/// Chroma only accepts scalar metadata values, which `MetadataValue`
/// models directly.
pub(all) enum MetadataValue {
  MString(String)
  MInt(Int32)
  MFloat(Double)
  MBool(Bool)
  MNull
} derive(Eq, Debug)

///|
/// Ordered list of `(key, value)` metadata pairs.
pub type Metadata = Array[(String, MetadataValue)]

///|
/// Converts a JSON scalar into a `MetadataValue`, returning `None` for
/// arrays and objects since Chroma rejects them as metadata.
pub fn MetadataValue::from_json(value : Json) -> MetadataValue? {
  match value {
    Json::String(s) => Some(MString(s))
    Json::Number(n, ..) =>
      // Chroma round-trips integers and floats through the same JSON number
      // type, so integral values are reported back as `MInt`.
      if n == n.floor() && n.abs() < 9.007199254740992e15 {
        Some(MInt(n.to_int()))
      } else {
        Some(MFloat(n))
      }
    Json::True => Some(MBool(true))
    Json::False => Some(MBool(false))
    Json::Null => Some(MNull)
    Json::Array(_) | Json::Object(_) => None
  }
}

///|
/// Converts a `MetadataValue` into the JSON representation Chroma expects.
pub fn MetadataValue::to_json(self : MetadataValue) -> Json {
  match self {
    MString(s) => Json::string(s)
    MInt(i) => Json::number(i.to_double(), repr=i.to_string())
    MFloat(f) => Json::number(f)
    MBool(b) => Json::boolean(b)
    MNull => Json::null()
  }
}

///|
/// Converts a `Metadata` list into a JSON object.
pub fn metadata_to_json(metadata : Metadata) -> Json {
  let fields : Map[String, Json] = Map([])
  for entry in metadata {
    let (key, value) = entry
    fields[key] = value.to_json()
  }
  Json::object(fields)
}

///|
/// Reads a JSON object into a `Metadata`.
///
/// Values Chroma cannot store (arrays and objects) are skipped rather than
/// failing the whole response.
pub fn metadata_from_json(json : Json) -> Metadata {
  match json {
    Json::Object(fields) => {
      let out : Metadata = []
      for entry in fields {
        let (key, value) = entry
        match MetadataValue::from_json(value) {
          Some(v) => out.push((key, v))
          None => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// A vector embedding as returned or requested by Chroma.
pub type Embedding = Array[Double]

///|
/// Converts an embedding to a JSON array of numbers.
pub fn embedding_to_json(embedding : Embedding) -> Json {
  let items : Array[Json] = []
  for value in embedding {
    items.push(Json::number(value))
  }
  Json::array(items)
}

///|
/// Reads a JSON array of numbers into an embedding.
pub fn embedding_from_json(json : Json) -> Embedding raise ChromaError {
  match json {
    Json::Array(items) => {
      let out : Embedding = []
      for item in items {
        match item {
          Json::Number(n, ..) => out.push(n)
          _ =>
            raise ChromaError::Decode("embedding contains a non-number element")
        }
      }
      out
    }
    _ => raise ChromaError::Decode("expected an array of numbers for embedding")
  }
}

///|
pub extend Config with Eq::{not_equal, equal}

///|
pub extend Config with @debug.Debug::{to_repr}

///|
pub extend MetadataValue with Eq::{not_equal, equal}

///|
pub extend MetadataValue with @debug.Debug::{to_repr}
