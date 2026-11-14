# Agent notes

`swift-curl` is a Swift library: it converts a Foundation `URLRequest` into a typed `CURLCommand` and renders it as a
shell command that is safe to paste into any POSIX shell. It does not wrap libcurl and performs no HTTP. Usage is in
`README.md`.

Read `CODING_STANDARDS.md` before writing code. Shell safety is the product: never weaken quoting, validation or a
round-trip test to make a change pass.

## Docs travel with code
`README.md` is the user documentation and DocC comments are the API reference. In the same change as any API or
behaviour change:
- Update the doc comment on every public declaration you touch.
- Update every README section, example and table the change affects (`grep -n "<Symbol>" README.md`).
- `site/index.html` is the landing page (GitHub Pages, `.github/workflows/pages.yml`). Its examples, install
  snippet and feature claims repeat the README: update them in the same change.

## Build and test
- `swift build --build-tests` and `swift test`; one test with `swift test --filter <Suite>/<test>`. The shell
  round-trip tests run each command in every POSIX shell installed (bash, sh/dash, zsh, ksh).
- CI (`.github/workflows/ci.yml`) runs Linux on Swift 6.0 and 6.1 and macOS, with warnings as errors: code must
  compile on 6.0 and without Apple-only Foundation.
- Architecture rules: `swift test --package-path Architecture` (macOS only) runs the mechanical part of
  `CODING_STANDARDS.md` as [swift-llm-check](https://github.com/mackoj/swift-llm-check) rules, listed in
  `docs/architecture-rules.md`. A failure prints the rule, why it exists and how to fix it: fix the code, never add a
  baseline. A new or changed rule needs its rationale and bad and good examples, a `DetectorTests` case, and
  `LLM_CHECK_RECORD=1 swift test --package-path Architecture` to regenerate the document.
- Benchmarks: `swift package --package-path Benchmarks benchmark`. A change made for speed or memory states its
  before and after in the pull request. Measuring, comparing and profiling: `docs/performance.md`.
- Pull requests also run `.github/workflows/soundness.yml`: actionlint and zizmor on the workflows.

## Releasing
Tags have no `v` prefix (`0.3.0`). A patch release for fixes and performance with no API change, a minor release for
new API. `gh release create <tag> --target main --title <tag> --notes "…"`.
