import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Shell substitutions")
struct SubstitutionTests {
  static let key = ShellSubstitution(literal: "s3cr3t", variable: "API_KEY")!

  @Test(arguments: [
    ("s3cr3t", #""$API_KEY""#),
    ("k=s3cr3t", #"'k='"$API_KEY""#),
    ("s3cr3t&q=1", #""$API_KEY"'&q=1'"#),
    ("a s3cr3t b s3cr3t", #"'a '"$API_KEY"' b '"$API_KEY""#),
    ("it's s3cr3t", #"'it'\''s '"$API_KEY""#),
    ("s3cr3ts3cr3t", #""$API_KEY""$API_KEY""#),
    ("nothing here", "'nothing here'"),
    ("", "''"),
  ])
  func quote(input: String, expected: String) {
    #expect(ShellEscaping.quote(input, substituting: [Self.key]) == expected)
  }

  @Test func noSubstitutionsQuotesAsBefore() {
    #expect(ShellEscaping.quote("it's $x", substituting: []) == ShellEscaping.quote("it's $x"))
  }

  @Test func longestLiteralWinsThenFirstGiven() {
    let short = ShellSubstitution(literal: "abc", variable: "SHORT")!
    let long = ShellSubstitution(literal: "abcdef", variable: "LONG")!
    let other = ShellSubstitution(literal: "abc", variable: "OTHER")!
    #expect(
      ShellEscaping.quote("abcdef abc", substituting: [short, long]) == #""$LONG"' '"$SHORT""#)
    #expect(ShellEscaping.quote("abc", substituting: [other, short]) == #""$OTHER""#)
  }

  @Test func matchesUnicodeScalarsExactly() {
    // "é" precomposed (U+00E9) and decomposed (e + U+0301) are different bytes.
    let precomposed = ShellSubstitution(literal: "\u{E9}", variable: "E")!
    #expect(ShellEscaping.quote("e\u{301}", substituting: [precomposed]) == "'e\u{301}'")
    #expect(ShellEscaping.quote("\u{E9}", substituting: [precomposed]) == #""$E""#)
  }

  @Test(arguments: ["", "1A", "A-B", "A B", "$A", "A}", "é", "A\n"])
  func rejectsInvalidVariableNames(name: String) {
    #expect(ShellSubstitution(literal: "x", variable: name) == nil)
  }

  @Test(arguments: ["A", "_", "_1", "api_key", "API_KEY_2"])
  func acceptsPOSIXNames(name: String) {
    #expect(ShellSubstitution(literal: "x", variable: name) != nil)
  }

  @Test func rejectsAnEmptyLiteralOrOneWithNUL() {
    #expect(ShellSubstitution(literal: "", variable: "A") == nil)
    #expect(ShellSubstitution(literal: "a\0b", variable: "A") == nil)
  }

  @Test func codableRoundTripAndValidation() throws {
    let options = CURLRenderOptions(
      layout: .multiline(indentation: "  "), substitutions: [Self.key])
    let data = try JSONEncoder().encode(options)
    #expect(try JSONDecoder().decode(CURLRenderOptions.self, from: data) == options)

    let invalid = Data(#"{"literal":"x","variable":"1A"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ShellSubstitution.self, from: invalid)
    }
  }

  @Test func decodesRenderOptionsWrittenBeforeSubstitutions() throws {
    let encoded = try JSONEncoder().encode(CURLRenderOptions.multiline)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["substitutions"] = nil
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(CURLRenderOptions.self, from: legacy) == .multiline)
  }

  @Test func renderSubstitutesURLValuesAndStandardInputButNotFlags() throws {
    var request = makeRequest(
      "https://example.com/pets?api_key=s3cr3t", method: "POST",
      headers: ["X-Key": "s3cr3t"], body: Data(utf8: #"{"key":"s3cr3t"}"#))
    let command = try request.curlCommand(
      options: .init {
        $0.additionalOptions = [.custom(flag: "--s3cr3t", value: nil)]
      })
    #expect(
      command.render(.init(layout: .multiline(indentation: "  "), substitutions: [Self.key]))
        == #"""
        curl 'https://example.com/pets?api_key='"$API_KEY" \
          -H 'X-Key: '"$API_KEY" \
          --data-raw '{"key":"'"$API_KEY"'"}' \
          --s3cr3t
        """#)

    request.httpBody = Data([0]) + Data("s3cr3t".utf8) + Data([1])
    let binary = try request.curlCommand()
    #expect(
      binary.render(.init(substitutions: [Self.key])).hasPrefix(
        #"{ printf '%s' 'AA==' | base64 --decode; printf '%s' "$API_KEY"; printf '%s' 'AQ==' | base64 --decode; } | curl "#
      ))
    // Without a match in its bytes, the payload renders as before.
    #expect(
      binary.render(.init(substitutions: [ShellSubstitution(literal: "zzz", variable: "Z")!]))
        == binary.render())
  }

  /// With each variable set to its literal, every shell hands curl exactly the
  /// unsubstituted argv: the substitution changes the text, never the request.
  @Test(arguments: Shell.available)
  func substitutedCommandsRunInRealShells(shell: String) throws {
    let secrets: [(literal: String, variable: String)] = [
      ("s3cr3t", "API_KEY"),
      ("it's $HOME `id` $(id) !! \\ \"x\" *", "HOSTILE"),
      ("line1\nline2", "MULTILINE"),
      ("-X DELETE", "LEADING_DASH"),
      ("中文 😀", "UNICODE"),
      ("[0-9]{a,b}", "GLOB"),
    ]
    let substitutions = secrets.map {
      ShellSubstitution(literal: $0.literal, variable: $0.variable)!
    }
    let environment = Dictionary(uniqueKeysWithValues: secrets.map { ($0.variable, $0.literal) })
    for secret in secrets {
      let value = "a " + secret.literal + "'b" + secret.literal
      let commands = [
        CURLCommand(
          url: "https://example.com/?q=" + value,
          options: [
            .request("POST"), .header(name: "X", value: value), .user(secret.literal),
            .dataRaw(value), .cookie("a=" + value),
          ]),
        CURLCommand(url: secret.literal, options: [.dataRaw(secret.literal)]),
        try makeRequest(
          "https://example.com/upload", method: "PUT",
          headers: ["X-Secret": secret.literal.replacingOccurrences(of: "\n", with: " ")],
          body: Data(secret.literal.utf8) + Data([0, 1, 2]) + Data(secret.literal.utf8)
            + Data([0xFF])
        ).curlCommand(),
      ]
      for command in commands {
        for format in ShellRoundTripTests.formats {
          var format = format
          format.substitutions = substitutions
          let rendered = command.render(format)
          #expect(!rendered.contains(secret.literal), "\(shell): \(rendered)")
          let invocation = try Shell.invoke(rendered, shell: shell, environment: environment)
          #expect(
            invocation.arguments == command.arguments(flagStyle: format.flagStyle),
            "\(shell): \(rendered)")
          #expect(invocation.standardInput == (command.standardInput?.data ?? Data()))
        }
      }
    }
    #expect(!FileManager.default.fileExists(atPath: "/tmp/swift-curl-pwned"))
  }
}
