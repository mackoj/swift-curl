import LLMCheck

extension Rule {
  static let quotingLivesInShellEscaping = Rule(
    id: "quoting-lives-in-shell-escaping",
    title:
      "Only `ShellEscaping` writes the `'\\''` escape; everything else calls `ShellEscaping.quote`.",
    category: .shellSafety,
    rationale: """
      Every value is single-quoted, and the only character that needs care inside single quotes is `'` itself \
      (CODING_STANDARDS.md, "One place quotes"). Escaping written by hand elsewhere, such as \
      `replacingOccurrences(of: "'", with: …)` or a literal `'\\''`, is a second implementation that the shell \
      round-trip tests may not reach, and the first fix to quoting would miss it.
      """,
    howToFix: """
      Call `ShellEscaping.quote(value)`, or `ShellEscaping.quote(value, substituting: format.substitutions)` for a \
      value that may hold a substituted literal. If quoting itself must change, change it in `ShellEscaping.swift` \
      and add a case to `ShellRoundTripTests`.
      """,
    badExample: """
      segment += " '" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
      """,
    goodExample: """
      segment += " " + ShellEscaping.quote(value, substituting: format.substitutions)
      """
  )

  static let expansionsOnlyThroughSubstitutions = Rule(
    id: "expansions-only-through-substitutions",
    title: "No string literal outside `ShellSubstitution.swift` holds `$` or a backtick.",
    category: .shellSafety,
    rationale: """
      `$` and backticks are where a shell runs code: `$VAR`, `$(…)`, `` `…` ``. The only expansion swift-curl emits \
      is a `ShellSubstitution.shellWord`, built from a validated POSIX variable name and a fixed pipeline per \
      `Encoding`, so no caller text can reach it (CODING_STANDARDS.md, "Expansions only through \
      `ShellSubstitution`"). A literal like `"$("` anywhere else is a new expansion that nothing validates. The \
      one-character literals `"$"` and `` "`" `` (characters in an HTTP token) cannot expand on their own and pass.
      """,
    howToFix: """
      Single-quote the value with `ShellEscaping.quote`. If the command really needs a new expansion, add it as a \
      `ShellSubstitution.Encoding` case, built only from fixed text and `"$" + variable`, with a test in \
      `EncodedSubstitutionTests` that runs it in every shell.
      """,
    badExample: """
      segments.append("\\"$(cat " + path + ")\\"")
      """,
    goodExample: """
      // ShellSubstitution.swift
      case .base64:
        return "\\"$(printf %s " + reference + " | base64 | tr -d '\\\\n')\\""
      """
  )

  static let onlyTheExecutableIsBare = Rule(
    id: "only-the-executable-is-bare",
    title: "`quoteIfNeeded` and `isSafeUnquoted` are used only on the executable name.",
    category: .shellSafety,
    rationale: """
      `quoteIfNeeded` leaves a word bare when it looks safe, which keeps `curl` readable. For a value that judgement \
      is one character-set bug away from an injection, and a bare value reads differently from every other value in \
      the command (CODING_STANDARDS.md, "Only the executable may be bare"). Values, the URL and non-plain flags are \
      always single-quoted.
      """,
    howToFix:
      "Use `ShellEscaping.quote(value)`; an empty or safe value simply gets two quotes around it.",
    badExample: """
      segment += " " + ShellEscaping.quoteIfNeeded(value)
      """,
    goodExample: """
      segments.append(ShellEscaping.quoteIfNeeded(executable) + " " + renderedURL(format))
      segment += " " + ShellEscaping.quote(value, substituting: format.substitutions)
      """
  )

  static let libraryPerformsNoIO = Rule(
    id: "library-performs-no-io",
    title: "The library performs no I/O, starts no process, reads no clock and logs nothing.",
    category: .purity,
    rationale: """
      swift-curl converts a request and renders text (CODING_STANDARDS.md, "Pure"): the same request gives the same \
      command on every machine, which the tests and the README examples rely on. A file read, a `Process`, `Date()` \
      or `UUID()` makes output depend on the host, and `print` writes into the caller's standard output. The only \
      bytes read are a caller's `httpBodyStream`, when `BodyStreamStrategy.read` asks for it.
      """,
    howToFix: """
      Take the value as a parameter or an option (`CURLConversionOptions`, `CURLRenderOptions`). Report a problem \
      as a `CURLConversionError`, never by printing. Running commands belongs in the tests (`Shell` in \
      `TestSupport.swift`).
      """,
    badExample: """
      let body = try Data(contentsOf: URL(fileURLWithPath: path))  // reads a file
      print(command.render())
      """,
    goodExample: """
      case .file(let path):
        return BodyPlan(options: [.dataBinary("@" + path)])  // curl reads the file, not the library
      """
  )

  static let urlRequestImportsFoundationNetworking = Rule(
    id: "urlrequest-imports-foundationnetworking",
    title:
      "A file that names `URLRequest` imports `FoundationNetworking` under `#if canImport(FoundationNetworking)`.",
    category: .platforms,
    rationale: """
      On Linux `URLRequest` lives in FoundationNetworking, not Foundation (CODING_STANDARDS.md, "Foundation only, \
      Linux too"). A file without the import builds on macOS, where these rules run, and fails only in the Linux CI \
      job; the guard keeps the import away from Apple platforms, where the module does not exist.
      """,
    howToFix:
      "Add the guarded import after `import Foundation`, as in `Sources/SwiftCURL/CURLConverter.swift`.",
    badExample: """
      import Foundation

      extension URLRequest { … }
      """,
    goodExample: """
      import Foundation

      #if canImport(FoundationNetworking)
        import FoundationNetworking
      #endif
      """
  )

  static let publicTypesAreSendable = Rule(
    id: "public-types-are-sendable",
    title: "A public struct, enum or class is declared `Sendable`.",
    category: .api,
    rationale: """
      The package builds in the Swift 6 language mode and promises `Sendable` throughout (CODING_STANDARDS.md, \
      "Sendable values"): a caller logs a `curlDescription` or keeps a `CURLCommand` across tasks. A conformance \
      left out is a source break to add later, since a client cannot add it. A caseless enum such as \
      `ShellEscaping` is a namespace and passes.
      """,
    howToFix: """
      Declare it on the type, like its neighbours: `public struct CURLCommand: Sendable, Hashable, Codable, …`. \
      Model types are also `Hashable` and `Codable`.
      """,
    badExample: "public struct CURLHeader: Hashable {",
    goodExample: "public struct CURLCookie: Sendable, Hashable, Codable {"
  )

  static let publicThrowsAreTyped = Rule(
    id: "public-throws-are-typed",
    title: "A public function or initializer throws a named error type, not `any Error`.",
    category: .api,
    rationale: """
      Every public conversion throws `CURLConversionError` (CODING_STANDARDS.md, "Typed throws"), so a caller \
      switches over what failed without casting, and `curlDescription` turns every case into an inert shell \
      comment. An untyped `throws` widens that contract for every caller. Codable's `init(from:)` and \
      `encode(to:)` pass: the protocol fixes their signature.
      """,
    howToFix:
      "Write `throws(CURLConversionError)`, and add a case to `CURLConversionError` for a new failure.",
    badExample: "public func command(for request: URLRequest) throws -> CURLCommand {",
    goodExample:
      "public func command(for request: URLRequest) throws(CURLConversionError) -> CURLCommand {"
  )

  static let testsUseSwiftTesting = Rule(
    id: "tests-use-swift-testing",
    title: "Tests use Swift Testing, never XCTest.",
    category: .testing,
    rationale: """
      The suite is Swift Testing only (CODING_STANDARDS.md, "Swift Testing only"): `@Test`, `#expect` and \
      `#require` give one failure style, and the shell round-trip tests are parameterised over every installed \
      shell.
      """,
    howToFix:
      "Write an `@Suite` of `@Test` functions with `#expect` and `#require`, and `import Testing`.",
    badExample: """
      import XCTest
      final class RenderingTests: XCTestCase { func testQuotes() { XCTAssertEqual(…) } }
      """,
    goodExample: """
      import Testing
      @Suite struct RenderingTests { @Test func quotes() { #expect(…) } }
      """
  )

  static let testsAreNotDisabled = Rule(
    id: "tests-are-not-disabled",
    title: "No test or suite is `.disabled`.",
    category: .testing,
    rationale: """
      A disabled test still reads as coverage while checking nothing (CODING_STANDARDS.md, "Nothing disabled"). \
      For a shell-safety library a silenced round-trip test is a silenced proof. `.enabled(if:)` remains for a \
      missing tool, such as no POSIX shell on the machine.
      """,
    howToFix:
      "Fix the code or the test. If the environment lacks a tool, gate on it with `.enabled(if:, \"…\")`.",
    badExample: "@Test(.disabled(\"flaky on zsh\")) func hostileValuesSurviveIntact() throws {",
    goodExample: "@Suite(.enabled(if: !Shell.available.isEmpty, \"No POSIX shell available\"))"
  )
}

/// Every rule, in the order `docs/architecture-rules.md` lists them.
let allRules: [Rule] = [
  .quotingLivesInShellEscaping, .expansionsOnlyThroughSubstitutions, .onlyTheExecutableIsBare,
  .libraryPerformsNoIO, .urlRequestImportsFoundationNetworking, .publicTypesAreSendable,
  .publicThrowsAreTyped,
  .testsUseSwiftTesting, .testsAreNotDisabled,
]
