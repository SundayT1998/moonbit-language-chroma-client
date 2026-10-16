///|
/// Measures the cost of serializing a large record batch.
///
/// `records_to_columns` builds a `Json` value and `Json::stringify` renders
/// it to the request body. The question this answers is whether that
/// intermediate representation is a bottleneck at realistic batch sizes, or
/// whether a hand-rolled streaming writer would be worth its complexity.
///
/// The measurement is a wall clock around a loop and its job is to be right
/// about the order of magnitude, not the microsecond.
///
/// It runs only when `CHROMA_BENCH=1` is set, so an ordinary `moon test`
/// neither pays for the loop nor fills the output with numbers.
test "bench: serializing a large record batch" {
  if @env.get_env_var("CHROMA_BENCH") != Some("1") {
    return
  }
  let sizes : Array[Int32] = [1000, 5000, 20000]
  let rounds = 200
  for size in sizes {
    // One warm-up batch, so the first allocation is not counted.
    ignore(bench_batch(size))
    let start = @env.now()
    let mut bytes = 0
    let mut round = 0
    while round < rounds {
      bytes = bench_batch(size)
      round = round + 1
    }
    let elapsed = @env.now() - start
    println(
      "records=" +
      size.to_string() +
      " rounds=" +
      rounds.to_string() +
      " total_us=" +
      elapsed.to_string() +
      " per_batch_us=" +
      (elapsed / rounds.to_uint64()).to_string() +
      " bytes=" +
      bytes.to_string(),
    )
  }
}

///|
/// Builds and stringifies a batch of `size` records, returning the body
/// length in bytes.
fn bench_batch(size : Int32) -> Int32 {
  let records : Array[@chroma-client.Record] = []
  let mut index = 0
  while index < size {
    records.push(
      @chroma-client.Record::of_embedding(
        "id-" + index.to_string(),
        [index.to_double(), 1.0, 2.0, 3.0],
        metadata=[
          ("topic", @chroma-client.MString("language")),
          ("n", @chroma-client.MInt(index)),
        ],
      ),
    )
    index = index + 1
  }
  @chroma-client.records_to_columns(records).stringify().length()
}

///|
/// The same batch written by hand into a `StringBuilder`, to compare against
/// the `Json` tree path.
///
/// This is the "streaming concatenation" alternative the issue asks about:
/// it walks the records once and appends straight to the output, with no
/// intermediate `Json` value and no `stringify` pass. It is here only as a
/// baseline; nothing in the client uses it.
fn bench_batch_streamed(size : Int32) -> Int32 {
  let out = StringBuilder()
  out.write_string("{\"ids\":[")
  let mut index = 0
  while index < size {
    if index > 0 {
      out.write_string(",")
    }
    out.write_string("\"id-" + index.to_string() + "\"")
    index = index + 1
  }
  out.write_string("],\"embeddings\":[")
  index = 0
  while index < size {
    if index > 0 {
      out.write_string(",")
    }
    out.write_string("[" + index.to_string() + ",1,2,3]")
    index = index + 1
  }
  out.write_string("],\"metadatas\":[")
  index = 0
  while index < size {
    if index > 0 {
      out.write_string(",")
    }
    out.write_string("{\"topic\":\"language\",\"n\":" + index.to_string() + "}")
    index = index + 1
  }
  out.write_string("]}")
  out.to_string().length()
}

///|
test "bench: json tree versus a streamed body" {
  if @env.get_env_var("CHROMA_BENCH") != Some("1") {
    return
  }
  let rounds = 200
  for size in ([5000, 20000] : Array[Int32]) {
    ignore(bench_batch(size))
    ignore(bench_batch_streamed(size))
    let tree_start = @env.now()
    let mut round = 0
    while round < rounds {
      ignore(bench_batch(size))
      round = round + 1
    }
    let tree_us = (@env.now() - tree_start) / rounds.to_uint64()
    let stream_start = @env.now()
    round = 0
    while round < rounds {
      ignore(bench_batch_streamed(size))
      round = round + 1
    }
    let stream_us = (@env.now() - stream_start) / rounds.to_uint64()
    println(
      "records=" +
      size.to_string() +
      " json_tree_us=" +
      tree_us.to_string() +
      " streamed_us=" +
      stream_us.to_string(),
    )
  }
}
