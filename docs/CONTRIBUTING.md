# Contributing

Thanks for looking at `chroma-client`. This document is the short version of
how changes get made here: what the workflow is, what a change has to prove,
and what the code is expected to look like.

## Getting set up

You need the [MoonBit toolchain](https://www.moonbitlang.com/download/) and
nothing else — no Chroma server, no Docker. Install it with the official
script for your system:

```bash
# Linux & macOS
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
```

```powershell
# Windows, in PowerShell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.com/install/powershell.ps1 | iex
```

Then check what you got and refresh the dependency index:

```bash
moon version --all      # the module is developed against 0.1.20261012
moon update
```

CI installs the toolchain the same way (`.github/workflows/ci.yml`); CNB bakes
it into `.cnb/Dockerfile`.

The module declares `preferred_target = "wasm"`, but `native` is the target CI
uses for tests (the async transport needs a runtime that supports
`moonbitlang/async`; `wasm-gc` does not exist yet).

## Before you open a PR

Run the same script CI runs:

```bash
sh scripts/ci.sh
```

That is, in order: `moon fmt --check`, `moon check --target native --deny-warn`,
`moon info` (plus a check that the generated `.mbti` files did not drift),
`moon test --target native --deny-warn --enable-coverage`, the coverage
reports, the coverage gate, and debug + release builds. A single step on its
own:

```bash
sh scripts/ci.sh fmt check     # just formatting and type-checking
sh scripts/ci.sh test coverage # just tests and coverage
sh scripts/ci.sh gate          # just the coverage threshold
```

Every step has to be green. `moon check --deny-warn` means warnings are
errors: if you introduce one, fix it rather than suppressing it.

## Tests

Two layers, and a change usually needs at least the first.

**Unit tests** live next to the code, in `*_test.mbt` (blackbox) and
`*_wbtest.mbt` (whitebox) files, and run without any server. They drive the
client through `MemoryTransport`, which replays scripted responses. Prefer
plain assertions (`assert_eq`) for results that are stable; for structured
debugging output, derive `Debug` and use `debug_inspect` snapshot tests, and
refresh them with `moon test --update`.

**Async unit tests** live in `scripted_async_wbtest.mbt`, next to the
`ScriptedAsyncTransport` double in `scripted_transport_wbtest.mbt`. They exist
because `MemoryTransport` cannot drive the `_async` methods: those take an
`AsyncTransport`, and an `async` call cannot be made from a synchronous
implementation. The doubles are private to the package (whitebox), so they do
not widen the public API — use them for anything that has to exercise the
request the `_async` methods build.

**Live tests** are `chroma_wbtest.mbt`. They run against a real Chroma server
and skip entirely when `CHROMA_ENDPOINT` is unset — that is why `scripts/ci.sh`
works with no Docker. To run them:

```bash
sh scripts/integration.sh      # starts chromadb/chroma, runs, tears down
```

or against a server you already have:

```bash
CHROMA_ENDPOINT=http://localhost:8000 \
  moon test --target native -p SundayT1998/chroma-client
```

They matter because scripted responses only prove the client agrees with
itself: the reshape of the record body to Chroma's columnar format, the bare
integer the count endpoints return, and the `new_metadata` field on
`modify_collection` were all found by a live server, not by the unit suite.
If your change touches the wire format, add or adjust a live test.

Set `CHROMA_TEST_RUN_ID` when several jobs share one server; each run
namespaces its collection names with it so parallel runs cannot collide.

## Coverage

`scripts/coverage_gate.sh` enforces the core-path target (>= 80% by default)
and runs as the `gate` step of `scripts/ci.sh`, after the coverage report.
"Core path" means every instrumented file except two:

- `cmd/main` — the demo executable, exercised by running it against a live
  server, not by the unit suite;
- `async_http_transport.mbt` — the real socket transport, which only the
  integration job can cover, because it needs a server to talk to.

Everything else — request building, decoding, error mapping, retries, URL
handling — counts. The gate reads the cobertura report, so run
`moon test --enable-coverage` and `moon coverage report -f cobertura` first if
you invoke it on its own:

```bash
sh scripts/ci.sh test coverage gate
```

A red gate means a new function has no test. Add one in the file next to the
code (`*_test.mbt` for the synchronous API, `*_wbtest.mbt` when it needs the
async doubles), rather than lowering the threshold.

## Performance

`bench_test.mbt` measures the cost of serializing a large record batch; it is
skipped unless `CHROMA_BENCH=1` is set, so ordinary runs do not pay for it.

```bash
CHROMA_BENCH=1 sh scripts/ci.sh test
```

The numbers and what they mean for the write path are in
[`docs/serialization-perf.md`](serialization-perf.md). Re-run it before
changing `records_to_columns`, and change that page rather than adding a
second table.

## Code style

- **Blocks.** MoonBit code is organised in blocks separated by `///|`. The
  order of blocks does not matter, so a block can usually be written, moved or
  reviewed on its own. Keep it that way.
- **Doc comments on public API.** Every `pub` item gets a doc comment — the
  first line is a one-sentence summary, then a blank `///` line, then the rest.
  The library's API reference is generated from these with `moon doc`. Write
  down *why* a thing behaves the way it does (a protocol quirk, a rejected
  alternative) rather than restating the signature.
- **Deprecated blocks** live in `deprecated.mbt` in each package.
- **Packages are named by content**, not by Go-style visibility. A package is
  `http`, never `internal/http`. Do not introduce `internal/` or `pkg/`
  directories.
- **Format before committing**: `moon fmt`.
- **Interfaces are checked in.** After a change, run `moon info && moon fmt`
  and review the `.mbti` diff. If the diff is empty, the change was not visible
  to users of the package — usually a safe refactor. If it is not empty, make
  sure every line of it is intended, and say so in the PR description.

## Commits and PRs

Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org):

```
feat: add peek to the collection API
fix: decode bare-integer counts
refactor: flatten the integration package into the root package
docs: move contributor docs into docs/
```

The body of a commit and of a PR description should say **what problem the
change solves**, not only what moved. This repository's PRs are read as design
notes, so the useful shape is:

- **现状问题** — what is wrong today, with evidence (a failing test, a live
  server response, a bug the current code cannot express);
- **改动点** — what changed, and why this shape rather than another;
- **放弃方案** — the alternatives considered and why they were dropped;
- **验证** — the commands run and their result.

Link the issue the PR closes (`Closes #10`, `Ref: #3`).

Try to keep a PR to one concern. If you notice unrelated problems while
working, open an issue rather than folding the fix into the same PR — or, if it
is small and clearly related, say so explicitly in the description.

## Reporting a bug

Include the Chroma version, the target backend (`native` / `wasm` / `js`), the
smallest call that reproduces it, and what you expected instead. If the client
rejected something locally, the `InvalidArgument` message names the record or
the argument; paste it. If the server rejected it, paste the `ApiError`
(`status`, `error_code`, `message`) and the request method and path.

## Licensing

Contributions are accepted under Apache-2.0, the license the module already
carries.
