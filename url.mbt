///|
/// Joins a base URL and a path with exactly one separating slash, so
/// `join_url("http://localhost:8000/", "/api/v2")` is
/// `http://localhost:8000/api/v2`.
pub fn join_url(base : String, path : String) -> String {
  let trimmed = base.trim_end(chars="/").to_owned()
  let suffix = path.trim_start(chars="/").to_owned()
  if suffix.length() == 0 {
    trimmed
  } else {
    trimmed + "/" + suffix
  }
}

///|
/// Percent-encodes a single path segment.
///
/// Collection names may contain spaces and other characters that are not
/// legal in a URL path, so every dynamic segment goes through here.
pub fn encode_path_segment(segment : String) -> String {
  percent_encode(segment, space_as_plus=false)
}

///|
/// Percent-encodes a query component. Unlike a path segment a space may be
/// written as `+` here.
pub fn encode_query_component(value : String) -> String {
  percent_encode(value, space_as_plus=true)
}

///|
/// Appends `key=value` pairs to a URL, percent-encoding both sides.
pub fn append_query(url : String, params : Array[(String, String)]) -> String {
  if params.length() == 0 {
    return url
  }
  let out = StringBuilder()
  out.write_string(url)
  out.write_string(if url.contains("?") { "&" } else { "?" })
  let mut first = true
  for param in params {
    let (key, value) = param
    if !first {
      out.write_string("&")
    }
    first = false
    out.write_string(encode_query_component(key))
    out.write_string("=")
    out.write_string(encode_query_component(value))
  }
  out.to_string()
}

///|
fn percent_encode(value : String, space_as_plus~ : Bool) -> String {
  let out = StringBuilder()
  for c in value {
    match c {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.' | '~' =>
        out.write_char(c)
      ' ' if space_as_plus => out.write_char('+')
      _ => write_percent_encoded(out, c)
    }
  }
  out.to_string()
}

///|
/// Writes the UTF-8 bytes of a character as `%XX` escapes.
fn write_percent_encoded(out : StringBuilder, c : Char) -> Unit {
  let code = c.to_int()
  if code < 0x80 {
    write_hex_byte(out, code)
  } else if code < 0x800 {
    write_hex_byte(out, 0xC0 | (code >> 6))
    write_hex_byte(out, 0x80 | (code & 0x3F))
  } else if code < 0x10000 {
    write_hex_byte(out, 0xE0 | (code >> 12))
    write_hex_byte(out, 0x80 | ((code >> 6) & 0x3F))
    write_hex_byte(out, 0x80 | (code & 0x3F))
  } else {
    write_hex_byte(out, 0xF0 | (code >> 18))
    write_hex_byte(out, 0x80 | ((code >> 12) & 0x3F))
    write_hex_byte(out, 0x80 | ((code >> 6) & 0x3F))
    write_hex_byte(out, 0x80 | (code & 0x3F))
  }
}

///|
/// Writes one byte as `%XX`.
fn write_hex_byte(out : StringBuilder, value : Int32) -> Unit {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F",
  ]
  out.write_string("%")
  out.write_string(digits[(value >> 4) & 0xF])
  out.write_string(digits[value & 0xF])
}
