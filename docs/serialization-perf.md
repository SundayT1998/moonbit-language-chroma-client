# Record serialization: is `records_to_columns` fast enough?

The question this page answers is whether the client's write path — build a
`Json` tree, then `Json::stringify` it — costs too much for large batches, and
whether it should be replaced by a hand-rolled streaming writer.

Short version: **it does not, at any batch size a Chroma server will accept.**
The measurements are below; the streaming alternative is about 10x faster in
isolation but saves microseconds, while costing the column alignment and null
padding that make the body correct.

## What the write path does

`add` / `upsert` / `update` all call `records_to_columns(records)`, which walks
the batch once and builds four parallel `Array[Json]` columns (`ids`,
`embeddings`, `documents`, `metadatas`), then wraps them in one
`Json::object`. `ChromaClient::send` calls `.stringify()` on the result once,
producing the request body.

So a batch of *n* records costs: *n* small `Json` values per column, plus one
`stringify` pass over the whole tree.

## Measured

`bench_test.mbt` times `records_to_columns(...).stringify()` over a batch of
records with a 4-dimension embedding and a two-key metadata object each, and
compares it against a hand-written `StringBuilder` version that appends the
body directly. Both produce a comparable body; the streamed one is only
exercised by the benchmark.

Measured on a Linux amd64 container (CNB runner image), `native` target,
200 rounds per size, median-ish wall clock per batch:

| records | body size | JSON tree | streamed |
| --- | --- | --- | --- |
| 1,000 | 49 KB | 2 us | — |
| 5,000 | 262 KB | 11 us | 1 us |
| 20,000 | 1.09 MB | 55 us | 7 us |

Reproduce with:

```bash
moon test --target native -p SundayT1998/chroma-client
# set CHROMA_BENCH=0 to skip the benchmark
```

## What that means

At 20,000 records the tree path spends **55 microseconds** preparing a
**1.09 MB** body — roughly 20 GB/s, which is memory-bandwidth territory and
nowhere near the cost of the request that follows it. A local HTTP round-trip
to Chroma is on the order of milliseconds; the serialization is three orders
of magnitude below it.

A batch that large is already unusual: Chroma's own max batch size default is
well below it, and a caller sending 20,000 vectors is paying far more for the
embedding computation that produced them and for the server's index update
than for the JSON.

The streamed writer is ~8x faster (7 us vs 55 us), so it would save 48
microseconds per 20,000-record write — under 0.01% of the round-trip, in
exchange for:

- hand-writing the JSON escaping and number formatting the `Json` package
  already does correctly;
- keeping the column/null-padding rules (`null` for a missing document or
  metadata, `null` for an `update` field left alone) in two places rather than
  one;
- a second body-building path that has to be kept in step with the first.

That trade is not worth making. The write path stays as it is.

## When to revisit

The measurement above is per-batch CPU, which is the part this client
controls. Two things would change the conclusion:

- **A much larger batch size.** If Chroma raised its limit into the
  hundreds of thousands of records per request, 55 us would become ~1 ms and
  the streamed path ~0.1 ms — still small next to the round-trip, but no
  longer free. Re-run the benchmark before assuming either way.
- **A real profile showing serialization in the hot path.** If an application
  profile ever puts `stringify` at the top of the stack, that is the evidence
  to act on, not this table.

Neither is true today, so no change is made.
