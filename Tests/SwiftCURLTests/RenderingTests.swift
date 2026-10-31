import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Rendering")
struct RenderingTests {
  static let request = makeRequest(
    "https://api.example.com/v1/items?id=42", method: "PATCH",
    headers: ["Content-Type": "application/json", "Accept": "application/json"],
    body: Data(utf8: #"{"name":"O'Brien"}"#))

  @Test func singleLine() throws {
    #expect(
      try Self.request.curl(format: .singleLine)
        == #"curl 'https://api.example.com/v1/items?id=42' -X 'PATCH' -H 'Accept: application/json' -H 'Content-Type: application/json' --data-raw '{"name":"O'\''Brien"}'"#
    )
  }

  @Test func multiline() throws {
    #expect(
      try Self.request.curl(format: .multiline) == #"""
        curl 'https://api.example.com/v1/items?id=42' \
          -X 'PATCH' \
          -H 'Accept: application/json' \
          -H 'Content-Type: application/json' \
          --data-raw '{"name":"O'\''Brien"}'
        """#)
  }

  @Test func multilineCustomIndentationAndLongFlags() throws {
    let format = CURLRenderOptions(layout: .multiline(indentation: "\t"), flagStyle: .long)
    let command = CURLCommand(url: "https://x.test", options: [.location, .user("u:p")])
    #expect(command.render(format) == "curl 'https://x.test' \\\n\t--location \\\n\t--user 'u:p'")
  }

  @Test func multilineWithPipeline() {
    let command = CURLCommand(
      url: "https://x.test", options: [.dataBinary("@-")],
      standardInput: .init(data: Data([0, 1, 2])))
    #expect(
      command.render(.multiline) == """
        printf '%s' 'AAEC' \\
          | base64 --decode \\
          | curl 'https://x.test' \\
          --data-binary '@-'
        """)
    #expect(
      command.description
        == "printf '%s' 'AAEC' | base64 --decode | curl 'https://x.test' --data-binary '@-'")
  }

  @Test func descriptionIsSingleLine() throws {
    let command = try Self.request.curlCommand()
    #expect(command.description == command.render(.singleLine))
    let rendered = try Self.request.curl()
    #expect("\(command)" == rendered)
  }

  @Test func urlStartingWithDashUsesURLFlag() {
    let command = CURLCommand(url: "-o/etc/passwd")
    #expect(command.render() == "curl --url '-o/etc/passwd'")
    #expect(command.arguments() == ["--url", "-o/etc/passwd"])
  }

  @Test func unsafeCustomFlagIsQuoted() {
    let command = CURLCommand(
      url: "https://x.test", options: [.custom(flag: "--x; rm -rf ~", value: nil)])
    #expect(command.render() == "curl 'https://x.test' '--x; rm -rf ~'")
  }

  @Test func argumentsMatchCurlArgv() throws {
    let command = try Self.request.curlCommand()
    #expect(
      command.arguments() == [
        "https://api.example.com/v1/items?id=42",
        "-X", "PATCH",
        "-H", "Accept: application/json",
        "-H", "Content-Type: application/json",
        "--data-raw", #"{"name":"O'Brien"}"#,
      ])
  }

  @Test(arguments: [
    (CURLOption.maxTime(30), ["-m", "30"]),
    (.maxTime(0.25), ["-m", "0.25"]),
    (.connectTimeout(5), ["--connect-timeout", "5"]),
    (.maxTime(.infinity), ["-m", "0"]),
    (.header(name: "A", value: "b"), ["-H", "A: b"]),
    (.compressed, ["--compressed"]),
    (.http1_1, ["--http1.1"]),
    (.custom(flag: "--retry", value: "2"), ["--retry", "2"]),
  ])
  func optionArguments(option: CURLOption, expected: [String]) {
    #expect(option.arguments() == expected)
  }

  @Test func everyOptionRendersWithBothFlagStyles() {
    let all: [CURLOption] = [
      .request("X"), .header(name: "A", value: "b"), .data("d"), .dataRaw("d"), .dataBinary("d"),
      .dataURLEncode("d"), .form("f=1"), .formString("f=1"), .cookie("a=b"), .cookieJar("j"),
      .user("u"), .userAgent("ua"), .referer("r"), .proxy("p"), .output("o"), .maxTime(1),
      .connectTimeout(1), .location, .compressed, .head, .get, .insecure, .verbose, .silent,
      .showError, .include, .fail, .globOff, .http1_1, .http2,
    ]
    for style in CURLOption.FlagStyle.allCases {
      for option in all {
        let flag = option.components(flagStyle: style).flag
        #expect(ShellEscaping.isPlainFlag(flag), "\(option) → \(flag)")
        if style == .long { #expect(flag.hasPrefix("--")) }
      }
    }
  }

  @Test func codableRoundTrip() throws {
    let command = CURLCommand(
      url: "https://x.test",
      options: [.header(name: "A", value: "b"), .maxTime(2), .custom(flag: "--z", value: nil)],
      standardInput: .base64("AA=="))
    let data = try JSONEncoder().encode(command)
    #expect(try JSONDecoder().decode(CURLCommand.self, from: data) == command)
  }

  @Test func errorDescriptionsAreSingleLine() {
    let errors: [CURLConversionError] = [
      .missingURL, .invalidHTTPMethod("A\nB"), .invalidHeaderName("x\r\ny"),
      .invalidHeaderValue(name: "n"), .binaryBodyNotAllowed(byteCount: 3),
      .bodyStreamNotSupported, .bodyStreamTooLarge(limit: 1), .bodyStreamReadFailed("e"),
    ]
    for error in errors {
      #expect(!error.description.contains("\n"))
      #expect(!error.description.contains("\r"))
    }
  }
}
