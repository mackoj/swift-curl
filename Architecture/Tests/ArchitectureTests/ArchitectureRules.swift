import LLMCheck
import Testing

/// The rules, run on the repository. A failure prints the rule, why it exists and how to fix it.
@Suite("Architecture rules")
struct ArchitectureRules {
  static func sources() throws -> Scope { try swiftCURL().productionCode.in("/Sources") }
  static func tests() throws -> Scope { try swiftCURL().testCode.in("/Tests") }

  @Test func quotingLivesInShellEscaping() throws {
    let sources = try Self.sources()
    #expect(sources.relativePaths.contains("Sources/SwiftCURL/ShellEscaping.swift"))
    expectNone(Detect.handWrittenQuoting(in: sources), rule: .quotingLivesInShellEscaping)
  }

  @Test func expansionsOnlyThroughSubstitutions() throws {
    let sources = try Self.sources()
    #expect(sources.relativePaths.contains("Sources/SwiftCURL/ShellSubstitution.swift"))
    expectNone(
      Detect.shellExpansionsOutsideSubstitution(in: sources),
      rule: .expansionsOnlyThroughSubstitutions)
  }

  @Test func onlyTheExecutableIsBare() throws {
    let sources = try Self.sources()
    #expect(!sources.calls(named: "quoteIfNeeded").isEmpty)
    expectNone(Detect.unquotedValues(in: sources), rule: .onlyTheExecutableIsBare)
  }

  @Test func libraryPerformsNoIO() throws {
    expectNone(Detect.impureCode(in: try Self.sources()), rule: .libraryPerformsNoIO)
  }

  @Test func urlRequestImportsFoundationNetworking() throws {
    let code = try swiftCURL().allCode.in("/Sources", "/Tests")
    #expect(code.references(to: "URLRequest").count > 5)
    expectNone(
      Detect.urlRequestWithoutFoundationNetworking(in: code),
      rule: .urlRequestImportsFoundationNetworking)
  }

  @Test func publicTypesAreSendable() throws {
    let sources = try Self.sources()
    #expect((sources.structs + sources.enums).withModifier("public").count > 10)
    expectNone(Detect.publicTypesNotSendable(in: sources), rule: .publicTypesAreSendable)
  }

  @Test func publicThrowsAreTyped() throws {
    expectNone(Detect.untypedPublicThrows(in: try Self.sources()), rule: .publicThrowsAreTyped)
  }

  @Test func testsUseSwiftTesting() throws {
    let tests = try Self.tests()
    #expect(tests.containing("import Testing").relativePaths.count > 5)
    expectNone(tests.xcTestImports, rule: .testsUseSwiftTesting)
  }

  @Test func testsAreNotDisabled() throws {
    expectNone(try Self.tests().disabledTests, rule: .testsAreNotDisabled)
  }

}

/// Keeps `docs/architecture-rules.md` in step with the rules. Regenerate with
/// `LLM_CHECK_RECORD=1 swift test --package-path Architecture`.
@Test func rulesDocumentIsUpToDate() throws {
  let catalog = RuleCatalog(allRules)
  #expect(catalog.duplicateIDs.isEmpty)
  try expectFile(
    "docs/architecture-rules.md", in: swiftCURL(),
    matches: catalog.markdown(
      title: "Architecture rules",
      introduction: """
        The mechanical part of `CODING_STANDARDS.md`, enforced by the `Architecture/` package with \
        [swift-llm-check](https://github.com/mackoj/swift-llm-check): `swift test --package-path Architecture` \
        (macOS). Generated from its rules; do not edit by hand.
        """))
}
