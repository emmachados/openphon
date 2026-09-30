# Contributing to openphon

Bug reports, measurement discrepancies and code changes are welcome through
[GitHub issues](https://github.com/emmachados/openphon/issues) and pull
requests. Contributions are accepted under the repository's Apache-2.0
licence.

## Reporting a problem

Use the issue forms. A measurement discrepancy needs the openphon version,
the analysis settings, the Praat version and settings it is compared with,
and the values from both. Attach audio only when you have the right to
share it publicly; a synthetic signal that reproduces the problem is
preferable to participant speech.

## Building and testing

Toolchain versions, platform setup and bridge generation are described in
the [application README](app/README.md). Before submitting a change, run
the checks that cover the code it touches:

```sh
cargo test --release --manifest-path core/Cargo.toml
cargo test --locked --manifest-path cli/Cargo.toml
cd app && flutter analyze --no-pub && flutter test --no-pub
```

Changes to the Rust API in `app/rust/src/api/` require regenerating the
Dart bindings with `flutter_rust_bridge_codegen generate` 2.12.0 from
`app/`, and committing the generated files.

## Changes to the analysis core

Code in `core/` is a clean-room implementation from published algorithm
descriptions and documented default parameters. Do not read, port or
paraphrase Praat's source code; cite the publication an algorithm comes
from in the module documentation.

Any change that can alter a number must pass the validation described in
[validation/README.md](validation/README.md), which CI runs on changes to
`core/`, `cli/` and `validation/`. Thresholds are not adjusted to make a
check pass. A parameter may be tuned only on the calibration subset of
the public tier (`partition_public.json`); the evaluation subset is scored
once, at the chosen value, and the result is reported whatever it is.
Record the calibration evidence in the code comment beside the parameter
and in [docs/VALIDATION.md](docs/VALIDATION.md).

## Data

Participant recordings never enter the repository, its history or an
issue. The public benchmark audio is fetched from its release archive by
`validation/fetch_public.py`; derived per-frame caches stay local.

## Line endings

Some files use CRLF line endings and others LF. Keep the ending a file
already has; editors that normalise whole files produce diffs that hide
the actual change.
