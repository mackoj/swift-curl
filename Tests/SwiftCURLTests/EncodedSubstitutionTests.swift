import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Encoded shell substitutions")
struct EncodedSubstitutionTests {
  /// RFC 3986 unreserved characters, the set ``ShellSubstitution/Encoding/percentEncoded`` keeps.
  static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func spelling(_ value: String, _ encoding: ShellSubstitution.Encoding) -> String {
    switch encoding {
    case .raw: value
    case .base64: Data(value.utf8).base64EncodedString()
    case .percentEncoded: value.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
  }

  @Test func shellWords() {
    #expect(ShellSubstitution(literal: "x", variable: "K")!.shellWord == #""$K""#)
    #expect(
      ShellSubstitution(literal: "x", variable: "K", encoding: .base64)!.shellWord
        == #""$(printf %s "$K" | base64 | tr -d '\n')""#)
    #expect(
      ShellSubstitution(literal: "x", variable: "K", encoding: .percentEncoded)!.shellWord
        == #""$(printf %s "$K" | od -A n -t x1 -v | awk '{for(i=1;i<=NF;i++){h=tolower($i);"#
        + #"d=index("0123456789abcdef",substr(h,1,1))*16+index("0123456789abcdef",substr(h,2,1))-17;"#
        + #"if(d>=48&&d<=57||d>=65&&d<=90||d>=97&&d<=122||d==45||d==46||d==95||d==126)printf "%c",d;"#
        + #"else printf "%%%s",toupper(h)}}')""#)
  }

  @Test func quoteWritesTheExpressionInPlaceOfTheLiteral() {
    let key = ShellSubstitution(literal: "czNjcjN0", variable: "KEY", encoding: .base64)!
    #expect(
      ShellEscaping.quote("Bearer czNjcjN0!", substituting: [key])
        == #"'Bearer '"$(printf %s "$KEY" | base64 | tr -d '\n')"'!'"#)
  }

  @Test func rawSubstitutionsRenderAsBefore() {
    let implicit = ShellSubstitution(literal: "s3cr3t", variable: "K")!
    let explicit = ShellSubstitution(literal: "s3cr3t", variable: "K", encoding: .raw)!
    #expect(implicit == explicit)
    #expect(ShellEscaping.quote("a=s3cr3t", substituting: [explicit]) == #"'a='"$K""#)
  }

  @Test func codable() throws {
    let raw = ShellSubstitution(literal: "x", variable: "K")!
    // A raw substitution encodes as it did before `encoding` existed.
    let object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: String]
    #expect(object == ["literal": "x", "variable": "K"])
    let legacy = Data(#"{"literal":"x","variable":"K"}"#.utf8)
    #expect(try JSONDecoder().decode(ShellSubstitution.self, from: legacy) == raw)

    for encoding in ShellSubstitution.Encoding.allCases {
      let substitution = ShellSubstitution(literal: "x", variable: "K", encoding: encoding)!
      let data = try JSONEncoder().encode(substitution)
      #expect(try JSONDecoder().decode(ShellSubstitution.self, from: data) == substitution)
    }
    let unknown = Data(#"{"literal":"x","variable":"K","encoding":"rot13"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ShellSubstitution.self, from: unknown)
    }
  }

  @Test func binaryBodyWritesTheExpression() throws {
    let key = ShellSubstitution(literal: "czNjcjN0", variable: "KEY", encoding: .base64)!
    let request = makeRequest(
      "https://example.com", method: "PUT", body: Data([0]) + Data("czNjcjN0".utf8))
    #expect(
      try request.curlCommand().render(.init(substitutions: [key])).hasPrefix(
        #"{ printf '%s' 'AA==' | base64 --decode; printf '%s' "$(printf %s "$KEY" | base64 | tr -d '\n')"; } | curl "#
      ))
  }

  /// With each variable set to the plain value, every shell hands curl the
  /// encoded spellings exactly: in the URL, a header, `-u`, a text body and a
  /// binary body, for every encoding at once, as an exporter passes them.
  @Test(arguments: Shell.available)
  func encodedSubstitutionsRunInRealShells(shell: String) throws {
    let secrets: [(value: String, variable: String)] = [
      ("s3cr3t", "API_KEY"),
      ("it's $HOME `id` $(id) !! \\ \"x\" * %41 +/=", "HOSTILE"),
      ("line1\nline2\n", "MULTILINE"),
      ("-n -e", "LEADING_DASH"),
      // No precomposed accent: `Process` hands the environment over decomposed (NFD).
      ("中文 😀 ~-._", "UNICODE"),
      ("[0-9]{a,b}", "GLOB"),
      (String(repeating: "abcdefghij", count: 12), "LONG"),
    ]
    let environment = Dictionary(uniqueKeysWithValues: secrets.map { ($0.variable, $0.value) })
    let substitutions = secrets.flatMap { secret in
      ShellSubstitution.Encoding.allCases.map {
        ShellSubstitution(
          literal: Self.spelling(secret.value, $0), variable: secret.variable, encoding: $0)!
      }
    }
    for secret in secrets {
      for encoding in ShellSubstitution.Encoding.allCases {
        let literal = Self.spelling(secret.value, encoding)
        let value = "a " + literal + "'b" + literal
        let commands = [
          CURLCommand(
            url: "https://example.com/?q=" + value,
            options: [
              .request("POST"), .header(name: "X", value: value), .user(literal),
              .dataRaw(value), .cookie("a=" + value),
            ]),
          try makeRequest(
            "https://example.com/upload", method: "PUT",
            body: Data(literal.utf8) + Data([0, 1, 2]) + Data(literal.utf8) + Data([0xFF])
          ).curlCommand(),
        ]
        for command in commands {
          var format = CURLRenderOptions(layout: .multiline(indentation: "  "))
          format.substitutions = substitutions
          let rendered = command.render(format)
          #expect(!rendered.contains(secret.value), "\(shell): \(rendered)")
          #expect(!rendered.contains(literal), "\(shell): \(rendered)")
          let invocation = try Shell.invoke(rendered, shell: shell, environment: environment)
          let context = "\(shell) \(secret.variable) \(encoding): \(rendered)"
          #expect(invocation.arguments == command.arguments(), "\(context)")
          #expect(invocation.standardInput == (command.standardInput?.data ?? Data()), "\(context)")
        }
      }
    }
    #expect(!FileManager.default.fileExists(atPath: "/tmp/swift-curl-pwned"))
  }
}
