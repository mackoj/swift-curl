import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Executes generated commands in real POSIX shells to prove they are
/// syntactically valid and that curl receives exactly the intended argv.
@Suite(
  "Shell round-trip",
  .enabled(if: !Shell.available.isEmpty, "No POSIX shell available")
)
struct ShellRoundTripTests {
  static let hostileStrings: [String] = [
    "",
    "'",
    "''",
    #"'\''"#,
    "\"",
    "$HOME",
    "${PATH}",
    "$(touch /tmp/swift-curl-pwned)",
    "`touch /tmp/swift-curl-pwned`",
    "!!",
    "!$",
    "\\",
    "\\'",
    "a;b|c&d",
    "> /tmp/x < /tmp/y",
    "*",
    "~",
    "#comment",
    "line1\nline2\n",
    "\r\n",
    "\t",
    "unicode é ü 中文 😀",
    "-X DELETE",
    "--data @/etc/passwd",
    "%s %n %%",
    "' ; echo pwned ; '",
    "{a,b}",
    "[0-9]",
  ]

  static let formats: [CURLRenderOptions] = [
    .singleLine, .multiline,
    .init(layout: .multiline(indentation: "\t"), flagStyle: .long),
  ]

  @Test(arguments: Shell.available)
  func hostileValuesSurviveIntact(shell: String) throws {
    for value in Self.hostileStrings {
      let command = CURLCommand(
        url: "https://example.com/?q=" + value,
        options: [
          .request(value), .header(name: "X", value: value), .dataRaw(value), .cookie(value),
          .custom(flag: value.isEmpty ? "--x" : value, value: value),
        ])
      for format in Self.formats {
        let rendered = command.render(format)
        let invocation = try Shell.invoke(rendered, shell: shell)
        #expect(
          invocation.arguments == command.arguments(flagStyle: format.flagStyle),
          "\(shell): \(rendered)")
      }
    }
    #expect(!FileManager.default.fileExists(atPath: "/tmp/swift-curl-pwned"))
  }

  @Test(arguments: Shell.available)
  func fuzzedValuesSurviveIntact(shell: String) throws {
    let alphabet = Array(
      "abcXYZ019 '\"`$!\\;&|<>(){}[]*?~#%^=,.:/-_+@\n\t\r é😀".unicodeScalars)
    var rng = SplitMix64(state: 0x5EED_CAFE)
    for _ in 0..<150 {
      let length = Int.random(in: 0...40, using: &rng)
      var value = ""
      for _ in 0..<length {
        value.unicodeScalars.append(alphabet.randomElement(using: &rng)!)
      }
      let command = CURLCommand(
        url: "https://example.com", options: [.dataRaw(value), .header(name: "V", value: value)])
      let rendered = command.render(Bool.random(using: &rng) ? .singleLine : .multiline)
      let invocation = try Shell.invoke(rendered, shell: shell)
      #expect(invocation.arguments == command.arguments(), "\(shell): \(rendered)")
    }
  }

  @Test(arguments: Shell.available)
  func binaryPipelineDeliversExactBytes(shell: String) throws {
    var rng = SplitMix64(state: 42)
    let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
    let request = makeRequest(
      "https://example.com/upload", method: "PUT",
      headers: ["Content-Type": "application/octet-stream"], body: payload)
    let command = try request.curlCommand()
    for format in Self.formats {
      let invocation = try Shell.invoke(command.render(format), shell: shell)
      #expect(invocation.standardInput == payload)
      #expect(invocation.arguments == command.arguments(flagStyle: format.flagStyle))
      #expect(invocation.arguments.suffix(2) == ["--data-binary", "@-"])
    }
  }

  @Test(arguments: Shell.available)
  func realisticRequestsRoundTrip(shell: String) throws {
    let requests: [URLRequest] = [
      makeRequest("https://api.example.com/search?q=it's&lang=en_US"),
      makeRequest(
        "https://api.example.com/users", method: "POST",
        headers: [
          "Content-Type": "application/json", "Authorization": "Bearer a.b.c",
          "Cookie": "sid=1; pref='dark'",
        ],
        body: Data(utf8: "{\n  \"bio\": \"I'm \\\"quoted\\\" & $rich\"\n}")),
      makeRequest("http://[::1]:8080/a", method: "HEAD"),
      makeRequest("https://example.com", method: "PROPFIND", headers: ["Depth": "1"]),
      MultipartTests.request(MultipartTests.textOnly),
      MultipartTests.request(MultipartTests.withFile),
    ]
    for request in requests {
      for options in [CURLConversionOptions.default, .logging] {
        let command = try request.curlCommand(options: options)
        for format in Self.formats {
          let rendered = command.render(format)
          #expect(try Shell.parses(rendered, shell: shell), "\(rendered)")
          let invocation = try Shell.invoke(rendered, shell: shell)
          #expect(invocation.arguments == command.arguments(flagStyle: format.flagStyle))
          #expect(invocation.standardInput == (command.standardInput?.data ?? Data()))
        }
      }
    }
  }

  @Test func renderedOutputNeverUsesDoubleQuotesForQuoting() throws {
    let request = makeRequest(
      "https://example.com/x", method: "POST",
      headers: ["X-A": "plain"], body: Data(utf8: "plain"))
    let rendered = try request.curl(format: .multiline)
    #expect(!rendered.contains("\""))
  }
}
