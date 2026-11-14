# Coding standards

Read during review. The rules that can be checked mechanically are enforced by `Architecture/` and listed in
[docs/architecture-rules.md](docs/architecture-rules.md); the rest are judgement calls.

## Shell safety

swift-curl's promise is that a rendered command, pasted into any POSIX shell, hands curl exactly
`CURLCommand.arguments()` and runs nothing else.

- **Every value is single-quoted.** Inside single quotes no POSIX shell expands anything. The only character that
  needs care is `'` itself, written `'\''`. Double quotes are never used to quote a value.
- **One place quotes.** `ShellEscaping` is the only code that writes quoting. Everything else calls
  `ShellEscaping.quote`, so a fix to quoting is a fix everywhere.
- **Expansions only through `ShellSubstitution`.** The only `$` the library emits is a `ShellSubstitution.shellWord`:
  a validated POSIX variable name inside double quotes, or one of its fixed encoding pipelines. No other code builds a
  string holding `$` or a backtick.
- **Only the executable may be bare.** `quoteIfNeeded` exists for the executable name; values, the URL and custom
  flags that are not plain flags are quoted.
- **Reject what cannot be expressed safely.** A method or header name outside the RFC 9110 token set, a header value
  with CR, LF or NUL, throws `CURLConversionError`. Bytes a shell argument cannot carry (NUL, control characters) go
  through standard input as base64, never through an argument.
- **Proved in real shells.** A change to rendering adds a case to `ShellRoundTripTests` or
  `EncodedSubstitutionTests`, which run the command in bash, sh/dash, zsh and ksh and compare the argv and standard
  input curl receives.

## Library

- **Pure.** The library converts and renders; it performs no I/O, starts no process, reads no clock and logs nothing.
  The only bytes it reads are those of a caller's `httpBodyStream`, when the caller asks for it.
- **Foundation only, Linux too.** No third-party dependency. A file that names `URLRequest` imports
  `FoundationNetworking` under `#if canImport(FoundationNetworking)`.
- **Sendable values.** Public types are `Sendable`; the model types (`CURLCommand`, `CURLOption`,
  `CURLRenderOptions`, `ShellSubstitution`) are also `Hashable` and `Codable`, and a new field decodes payloads
  written before it existed.
- **Typed throws.** Public API throws `CURLConversionError`, never `any Error`, so callers can switch over failures.
- **Byte-exact by default.** `CURLConversionOptions.default` reproduces the request exactly; anything lossy (`omit`,
  redaction) is opt-in and documented as not faithful.

## Tests

- **Swift Testing only.** `@Suite`, `@Test`, `#expect`, `#require`; no XCTest.
- **Nothing disabled.** A test is fixed or removed, not `.disabled`. `.enabled(if:)` is for missing tools (no shell
  installed), never for a failure.

## Performance

- Rendering and conversion are measured in `Benchmarks/` ([docs/performance.md](docs/performance.md)). A change to a
  hot path (quoting, substitution, body classification, header handling) states its before and after.
