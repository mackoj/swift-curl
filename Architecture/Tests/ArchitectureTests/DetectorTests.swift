import LLMCheck
import Testing

/// Each detector on snippets: it finds what its rule forbids and nothing its rule allows.
@Suite struct DetectorTests {
  func scope(_ source: String, at path: String = "Sources/SwiftCURL/File.swift") -> Scope {
    Scope(files: [SourceFile(path: path, source: source)])
  }

  @Test func handWrittenQuotingIsFound() {
    let found = Detect.handWrittenQuoting(
      in: scope(
        #"""
        let a = "'" + value.replacingOccurrences(of: "'", with: "x") + "'"
        let b = #"'\''"#
        let c = "'\\''"
        let d = "it'\\''s \(name)"
        """#))
    #expect(found.map(\.location.line).sorted() == [1, 2, 3, 4])
  }

  @Test func quotingInShellEscapingPasses() {
    let source = #"""
      result.unicodeScalars.append(contentsOf: #"'\''"#.unicodeScalars)
      """#
    let found = Detect.handWrittenQuoting(
      in: scope(source, at: "Sources/SwiftCURL/ShellEscaping.swift"))
    #expect(found.isEmpty)
    let elsewhere = Detect.handWrittenQuoting(
      in: scope(
        #"""
        // '\'' in a comment is fine
        let printf = "printf '%s' "
        let other = text.replacingOccurrences(of: "\n", with: " ")
        """#))
    #expect(elsewhere.isEmpty)
  }

  @Test func shellExpansionsAreFound() {
    let found = Detect.shellExpansionsOutsideSubstitution(
      in: scope(
        #"""
        let a = "\"$HOME\""
        let b = "$(" + command + ")"
        let c = "`id`"
        let d = "${\(name)}"
        """#))
    #expect(found.map(\.location.line) == [1, 2, 3, 4])
  }

  @Test func singleCharacterTokensAndSubstitutionsPass() {
    let tokens = Detect.shellExpansionsOutsideSubstitution(
      in: scope(
        #"""
        switch scalar { case "!", "#", "$", "%", "`", "|": true; default: false }
        // "$HOME" in a comment is fine
        """#))
    #expect(tokens.isEmpty)
    let substitution = Detect.shellExpansionsOutsideSubstitution(
      in: scope(
        #"let reference = "\"$" + variable + "\"""#, at: "Sources/SwiftCURL/ShellSubstitution.swift"
      ))
    #expect(substitution.isEmpty)
  }

  @Test func unquotedValuesAreFound() {
    let found = Detect.unquotedValues(
      in: scope(
        """
        segment += " " + ShellEscaping.quoteIfNeeded(value)
        if ShellEscaping.isSafeUnquoted(url) { segments.append(url) }
        segments.append(ShellEscaping.quoteIfNeeded(executable) + " " + url)
        """))
    #expect(found.map(\.location.line) == [1, 2])
  }

  @Test func impureCodeIsFound() {
    let found = Detect.impureCode(
      in: scope(
        """
        let files = FileManager.default
        let process = Process()
        let now = Date()
        let id = UUID()
        print("rendered")
        NSLog("rendered")
        """))
    #expect(found.map(\.location.line).sorted() == [1, 2, 3, 4, 5, 6])
  }

  @Test func pureCodePasses() {
    let found = Detect.impureCode(
      in: scope(
        """
        // FileManager and Process are fine in a comment.
        let message = "print() and Date() are fine in a string"
        let epoch = Date(timeIntervalSince1970: 0)
        let count = stream.read(&buffer, maxLength: chunkSize)
        """))
    #expect(found.isEmpty)
  }

  @Test func urlRequestWithoutFoundationNetworkingIsFound() {
    let found = Detect.urlRequestWithoutFoundationNetworking(
      in: Scope(files: [
        SourceFile(
          path: "Sources/SwiftCURL/A.swift",
          source: "import Foundation\nextension URLRequest {}\nlet r: URLRequest"),
        SourceFile(
          path: "Sources/SwiftCURL/B.swift",
          source: "import FoundationNetworking\nfunc f(_ r: URLRequest) {}"),
        SourceFile(
          path: "Sources/SwiftCURL/C.swift",
          source: """
            #if canImport(FoundationNetworking)
            #else
              import FoundationNetworking
            #endif
            let r: URLRequest
            """),
      ]))
    #expect(
      found.map(\.location.description) == [
        "Sources/SwiftCURL/A.swift:2:11", "Sources/SwiftCURL/B.swift:2:13",
        "Sources/SwiftCURL/C.swift:5:8",
      ])
  }

  @Test func guardedFoundationNetworkingPasses() {
    let found = Detect.urlRequestWithoutFoundationNetworking(
      in: scope(
        """
        import Foundation

        #if canImport(FoundationNetworking)
          import FoundationNetworking
        #endif

        extension URLRequest {}
        """))
    #expect(found.isEmpty)
  }

  @Test func publicTypesNotSendableAreFound() {
    let found = Detect.publicTypesNotSendable(
      in: scope(
        """
        public struct Header: Hashable {
          public enum Kind: Hashable { case plain }
        }
        public struct Cookie: Sendable, Hashable {}
        public enum ShellEscaping {}
        public enum Layout: Sendable { case singleLine }
        struct Internal {}
        """))
    #expect(found.map(\.qualifiedName) == ["Header", "Header.Kind"])
  }

  @Test func untypedPublicThrowsAreFound() {
    let found = Detect.untypedPublicThrows(
      in: scope(
        """
        public struct Converter {
          public func command(for request: URLRequest) throws -> CURLCommand {}
          public init(json: String) throws {}
          public func render() throws(CURLConversionError) -> String {}
          func helper() throws {}
          public func plain() -> String {}
        }
        public struct Model: Codable {
          public init(from decoder: any Decoder) throws {}
          public func encode(to encoder: any Encoder) throws {}
        }
        """))
    #expect(found.map(\.location.line) == [2, 3])
  }

  @Test func xcTestImportsAreFound() {
    let found = Detect.xcTestImports(
      in: scope("import XCTest\nimport Testing", at: "Tests/T/A.swift"))
    #expect(found.map(\.location.line) == [1])
  }

  @Test func disabledTestsAreFound() {
    let found = Detect.disabledTests(
      in: scope(
        """
        @Test(.disabled("flaky")) func a() {}
        @Suite(.disabled()) struct B {}
        @Suite(.enabled(if: !Shell.available.isEmpty, "No POSIX shell available")) struct C {}
        @Test func d() { rule.disabled() }
        """, at: "Tests/T/A.swift"))
    #expect(found.map(\.location.line) == [1, 2])
  }
}
