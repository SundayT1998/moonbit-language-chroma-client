# Contributing

Thanks for looking at `chroma-client`. This document is the short version of
how changes get made here: what the workflow is, what a change has to prove,
and what the code is expected to look like.

## Getting set up

You need the [MoonBit toolchain](https://docs.moonbitlang.com) and nothing
else — no Chroma server, no Docker:

```bash
moon version --all      # the module is developed against 0.1.20261012
moon update
```

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
reports, and debug + release builds. A single step on its own:

```bash
sh scripts/ci.sh fmt check     # just formatting and type-checking
sh scripts/ci.sh test coverage # just tests and coverage
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
