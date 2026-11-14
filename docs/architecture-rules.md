# Architecture rules

The mechanical part of `CODING_STANDARDS.md`, enforced by the `Architecture/` package with [swift-llm-check](https://github.com/mackoj/swift-llm-check): `swift test --package-path Architecture` (macOS). Generated from its rules; do not edit by hand.

## shell-safety

Quoting and expansions. Read before you change how anything is rendered as shell text.

### Only `ShellEscaping` writes the `'\''` escape; everything else calls `ShellEscaping.quote`.

`quoting-lives-in-shell-escaping`: Every value is single-quoted, and the only character that needs care inside single quotes is `'` itself (CODING_STANDARDS.md, "One place quotes"). Escaping written by hand elsewhere, such as `replacingOccurrences(of: "'", with: …)` or a literal `'\''`, is a second implementation that the shell round-trip tests may not reach, and the first fix to quoting would miss it.

**How to fix:** Call `ShellEscaping.quote(value)`, or `ShellEscaping.quote(value, substituting: format.substitutions)` for a value that may hold a substituted literal. If quoting itself must change, change it in `ShellEscaping.swift` and add a case to `ShellRoundTripTests`.

Bad:

```swift
segment += " '" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
```

Good:

```swift
segment += " " + ShellEscaping.quote(value, substituting: format.substitutions)
```

### No string literal outside `ShellSubstitution.swift` holds `$` or a backtick.

`expansions-only-through-substitutions`: `$` and backticks are where a shell runs code: `$VAR`, `$(…)`, `` `…` ``. The only expansion swift-curl emits is a `ShellSubstitution.shellWord`, built from a validated POSIX variable name and a fixed pipeline per `Encoding`, so no caller text can reach it (CODING_STANDARDS.md, "Expansions only through `ShellSubstitution`"). A literal like `"$("` anywhere else is a new expansion that nothing validates. The one-character literals `"$"` and `` "`" `` (characters in an HTTP token) cannot expand on their own and pass.

**How to fix:** Single-quote the value with `ShellEscaping.quote`. If the command really needs a new expansion, add it as a `ShellSubstitution.Encoding` case, built only from fixed text and `"$" + variable`, with a test in `EncodedSubstitutionTests` that runs it in every shell.

Bad:

```swift
segments.append("\"$(cat " + path + ")\"")
```

Good:

```swift
// ShellSubstitution.swift
case .base64:
  return "\"$(printf %s " + reference + " | base64 | tr -d '\\n')\""
```

### `quoteIfNeeded` and `isSafeUnquoted` are used only on the executable name.

`only-the-executable-is-bare`: `quoteIfNeeded` leaves a word bare when it looks safe, which keeps `curl` readable. For a value that judgement is one character-set bug away from an injection, and a bare value reads differently from every other value in the command (CODING_STANDARDS.md, "Only the executable may be bare"). Values, the URL and non-plain flags are always single-quoted.

**How to fix:** Use `ShellEscaping.quote(value)`; an empty or safe value simply gets two quotes around it.

Bad:

```swift
segment += " " + ShellEscaping.quoteIfNeeded(value)
```

Good:

```swift
segments.append(ShellEscaping.quoteIfNeeded(executable) + " " + renderedURL(format))
segment += " " + ShellEscaping.quote(value, substituting: format.substitutions)
```

## purity

The library is pure. Read before you reach for the file system, a process, a clock or a log.

### The library performs no I/O, starts no process, reads no clock and logs nothing.

`library-performs-no-io`: swift-curl converts a request and renders text (CODING_STANDARDS.md, "Pure"): the same request gives the same command on every machine, which the tests and the README examples rely on. A file read, a `Process`, `Date()` or `UUID()` makes output depend on the host, and `print` writes into the caller's standard output. The only bytes read are a caller's `httpBodyStream`, when `BodyStreamStrategy.read` asks for it.

**How to fix:** Take the value as a parameter or an option (`CURLConversionOptions`, `CURLRenderOptions`). Report a problem as a `CURLConversionError`, never by printing. Running commands belongs in the tests (`Shell` in `TestSupport.swift`).

Bad:

```swift
let body = try Data(contentsOf: URL(fileURLWithPath: path))  // reads a file
print(command.render())
```

Good:

```swift
case .file(let path):
  return BodyPlan(options: [.dataBinary("@" + path)])  // curl reads the file, not the library
```

## platforms

Linux support. Read before you add an `import` or use a networking type.

### A file that names `URLRequest` imports `FoundationNetworking` under `#if canImport(FoundationNetworking)`.

`urlrequest-imports-foundationnetworking`: On Linux `URLRequest` lives in FoundationNetworking, not Foundation (CODING_STANDARDS.md, "Foundation only, Linux too"). A file without the import builds on macOS, where these rules run, and fails only in the Linux CI job; the guard keeps the import away from Apple platforms, where the module does not exist.

**How to fix:** Add the guarded import after `import Foundation`, as in `Sources/SwiftCURL/CURLConverter.swift`.

Bad:

```swift
import Foundation

extension URLRequest { … }
```

Good:

```swift
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
```

## api

Public types and errors. Read before you add or change a public declaration.

### A public struct, enum or class is declared `Sendable`.

`public-types-are-sendable`: The package builds in the Swift 6 language mode and promises `Sendable` throughout (CODING_STANDARDS.md, "Sendable values"): a caller logs a `curlDescription` or keeps a `CURLCommand` across tasks. A conformance left out is a source break to add later, since a client cannot add it. A caseless enum such as `ShellEscaping` is a namespace and passes.

**How to fix:** Declare it on the type, like its neighbours: `public struct CURLCommand: Sendable, Hashable, Codable, …`. Model types are also `Hashable` and `Codable`.

Bad:

```swift
public struct CURLHeader: Hashable {
```

Good:

```swift
public struct CURLCookie: Sendable, Hashable, Codable {
```

### A public function or initializer throws a named error type, not `any Error`.

`public-throws-are-typed`: Every public conversion throws `CURLConversionError` (CODING_STANDARDS.md, "Typed throws"), so a caller switches over what failed without casting, and `curlDescription` turns every case into an inert shell comment. An untyped `throws` widens that contract for every caller. Codable's `init(from:)` and `encode(to:)` pass: the protocol fixes their signature.

**How to fix:** Write `throws(CURLConversionError)`, and add a case to `CURLConversionError` for a new failure.

Bad:

```swift
public func command(for request: URLRequest) throws -> CURLCommand {
```

Good:

```swift
public func command(for request: URLRequest) throws(CURLConversionError) -> CURLCommand {
```

## testing

Swift Testing, and no silenced tests. Read before you add, skip or change a test.

### Tests use Swift Testing, never XCTest.

`tests-use-swift-testing`: The suite is Swift Testing only (CODING_STANDARDS.md, "Swift Testing only"): `@Test`, `#expect` and `#require` give one failure style, and the shell round-trip tests are parameterised over every installed shell.

**How to fix:** Write an `@Suite` of `@Test` functions with `#expect` and `#require`, and `import Testing`.

Bad:

```swift
import XCTest
final class RenderingTests: XCTestCase { func testQuotes() { XCTAssertEqual(…) } }
```

Good:

```swift
import Testing
@Suite struct RenderingTests { @Test func quotes() { #expect(…) } }
```

### No test or suite is `.disabled`.

`tests-are-not-disabled`: A disabled test still reads as coverage while checking nothing (CODING_STANDARDS.md, "Nothing disabled"). For a shell-safety library a silenced round-trip test is a silenced proof. `.enabled(if:)` remains for a missing tool, such as no POSIX shell on the machine.

**How to fix:** Fix the code or the test. If the environment lacks a tool, gate on it with `.enabled(if:, "…")`.

Bad:

```swift
@Test(.disabled("flaky on zsh")) func hostileValuesSurviveIntact() throws {
```

Good:

```swift
@Suite(.enabled(if: !Shell.available.isEmpty, "No POSIX shell available"))
```
