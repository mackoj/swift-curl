import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Request bodies")
struct BodyTests {
  // MARK: Text / JSON

  @Test func jsonPost() throws {
    let json = #"{"name":"Ada","tags":["a","b"],"n":1}"#
    let request = makeRequest(
      "https://api.example.com/users", method: "POST",
      headers: ["Content-Type": "application/json"], body: Data(utf8: json))
    #expect(
      try request.curl()
        == #"curl 'https://api.example.com/users' -H 'Content-Type: application/json' --data-raw '{"name":"Ada","tags":["a","b"],"n":1}'"#
    )
  }

  @Test func jsonPutFromEncoder() throws {
    struct Payload: Encodable { var message: String }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = try encoder.encode(Payload(message: "it's $5 `now`!"))
    let request = makeRequest(
      "https://api.example.com/m/1", method: "PUT",
      headers: ["Content-Type": "application/json"], body: body)
    #expect(
      try request.curl()
        == #"curl 'https://api.example.com/m/1' -X 'PUT' -H 'Content-Type: application/json' --data-raw '{"message":"it'\''s $5 `now`!"}'"#
    )
  }

  @Test func multilineTextBodyIsKeptVerbatim() throws {
    let body = "{\n  \"a\": 1\n}\n"
    let request = makeRequest("https://example.com", method: "POST", body: Data(utf8: body))
    let command = try request.curlCommand()
    #expect(command.options == [.dataRaw(body)])
    #expect(command.render() == "curl 'https://example.com' --data-raw '\(body)'")
  }

  @Test func shellMetacharactersInBody() throws {
    let body = #"'; rm -rf / #  $(reboot) `halt` && echo "pwned" | tee x > y < z \ !!"#
    let request = makeRequest("https://example.com", method: "POST", body: Data(utf8: body))
    let command = try request.curlCommand()
    #expect(command.options == [.dataRaw(body)])
    #expect(command.render().contains(#"--data-raw ''\''; rm -rf / #"#))
  }

  // MARK: Empty vs nil

  @Test func nilBodyPost() throws {
    let request = makeRequest("https://example.com", method: "POST")
    #expect(try request.curl() == "curl 'https://example.com' -X 'POST'")
  }

  @Test func emptyBodyPost() throws {
    let request = makeRequest("https://example.com", method: "POST", body: Data())
    #expect(try request.curl() == "curl 'https://example.com' --data-raw ''")
  }

  @Test func emptyBodyPut() throws {
    let request = makeRequest("https://example.com", method: "PUT", body: Data())
    #expect(try request.curl() == "curl 'https://example.com' -X 'PUT' --data-raw ''")
  }

  @Test(arguments: ["GET", "HEAD"])
  func emptyBodyIsIgnoredForGetAndHead(method: String) throws {
    let request = makeRequest("https://example.com", method: method, body: Data())
    #expect(try !request.curlCommand().options.contains { $0.sendsBody })
  }

  // MARK: Text flag selection

  @Test func textBodyFlags() throws {
    let request = makeRequest("https://example.com", method: "POST", body: Data(utf8: "a=1"))
    let data = try request.curlCommand(options: .init { $0.textBodyFlag = .data })
    #expect(data.options == [.data("a=1")])
    #expect(data.render() == "curl 'https://example.com' -d 'a=1'")
    let binary = try request.curlCommand(options: .init { $0.textBodyFlag = .dataBinary })
    #expect(binary.options == [.dataBinary("a=1")])
  }

  @Test(arguments: [CURLConversionOptions.TextBodyFlag.data, .dataBinary, .dataRaw])
  func atPrefixedBodyNeverReadsAFile(flag: CURLConversionOptions.TextBodyFlag) throws {
    let request = makeRequest(
      "https://example.com", method: "POST", body: Data(utf8: "@/etc/passwd"))
    let command = try request.curlCommand(options: .init { $0.textBodyFlag = flag })
    #expect(command.options == [.dataRaw("@/etc/passwd")])
  }

  // MARK: Binary

  static let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A, 0xFF, 0x27])

  @Test func binaryDefaultsToBase64Pipeline() throws {
    let request = makeRequest(
      "https://example.com/upload", method: "POST",
      headers: ["Content-Type": "image/png"], body: Self.binary)
    let command = try request.curlCommand()
    #expect(command.standardInput == .base64(Self.binary.base64EncodedString()))
    #expect(command.standardInput?.data == Self.binary)
    #expect(
      command.render()
        == "printf '%s' 'iVBORwANChr/Jw==' | base64 --decode | curl 'https://example.com/upload'"
        + " -H 'Content-Type: image/png' --data-binary '@-'")
  }

  @Test func binaryFileStrategy() throws {
    let request = makeRequest("https://example.com", method: "PUT", body: Self.binary)
    let command = try request.curlCommand(
      options: .init { $0.binaryBodyStrategy = .file(path: "/tmp/my body.bin") })
    #expect(command.standardInput == nil)
    #expect(
      command.render()
        == "curl 'https://example.com' -X 'PUT' --data-binary '@/tmp/my body.bin'")
  }

  @Test func binaryOmitStrategy() throws {
    let request = makeRequest("https://example.com", method: "POST", body: Self.binary)
    let command = try request.curlCommand(options: .init { $0.binaryBodyStrategy = .omit })
    #expect(command.render() == "curl 'https://example.com' -X 'POST'")
  }

  @Test func binaryThrowStrategy() {
    let request = makeRequest("https://example.com", method: "POST", body: Self.binary)
    #expect(throws: CURLConversionError.binaryBodyNotAllowed(byteCount: Self.binary.count)) {
      try request.curlCommand(options: .init { $0.binaryBodyStrategy = .throwError })
    }
  }

  @Test(arguments: [
    Data([0x00]),  // NUL
    Data([0x61, 0x1B, 0x5B, 0x32, 0x4A]),  // ESC [2J (terminal escape)
    Data([0x61, 0x7F]),  // DEL
    Data([0xC2, 0x9B]),  // C1 CSI
    Data([0xC3, 0x28]),  // invalid UTF-8
    Data([0xFF, 0xFE]),
  ])
  func controlAndInvalidBytesAreBinary(data: Data) {
    #expect(BodyText.text(from: data) == nil)
  }

  @Test(arguments: ["tab\there", "crlf\r\n", "unicode é 😀 中文", "quote ' \" `"])
  func printableTextIsText(text: String) {
    #expect(BodyText.text(from: Data(utf8: text)) == text)
  }

  // MARK: Streams

  @Test func bodyStreamThrowsByDefault() {
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: Data(utf8: "streamed"))
    #expect(throws: CURLConversionError.bodyStreamNotSupported) { try request.curlCommand() }
  }

  @Test func bodyStreamOmit() throws {
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: Data(utf8: "streamed"))
    let command = try request.curlCommand(options: .init { $0.bodyStreamStrategy = .omit })
    #expect(command.render() == "curl 'https://example.com' -X 'POST'")
  }

  @Test func bodyStreamRead() throws {
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: Data(utf8: "streamed 'body'"))
    let command = try request.curlCommand(
      options: .init { $0.bodyStreamStrategy = .read(maxLength: 1024) })
    #expect(command.options == [.dataRaw("streamed 'body'")])
  }

  @Test func bodyStreamReadBinary() throws {
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: Self.binary)
    let command = try request.curlCommand(
      options: .init { $0.bodyStreamStrategy = .read(maxLength: 1024) })
    #expect(command.standardInput?.data == Self.binary)
  }

  @Test func bodyStreamReadLargeStream() throws {
    let payload = Data(String(repeating: "abcdefgh", count: 50_000).utf8)  // 400 KB
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: payload)
    let command = try request.curlCommand(
      options: .init { $0.bodyStreamStrategy = .read(maxLength: 1_000_000) })
    #expect(command.options == [.dataRaw(String(decoding: payload, as: UTF8.self))])
  }

  @Test func bodyStreamTooLarge() {
    var request = makeRequest("https://example.com", method: "POST")
    request.httpBodyStream = InputStream(data: Data(repeating: 0x61, count: 100))
    #expect(throws: CURLConversionError.bodyStreamTooLarge(limit: 10)) {
      try request.curlCommand(options: .init { $0.bodyStreamStrategy = .read(maxLength: 10) })
    }
  }

  // MARK: Logging preset

  @Test func loggingPresetOmitsBinaryAndStreams() throws {
    let binary = makeRequest("https://example.com", method: "POST", body: Self.binary)
    #expect(binary.curlDescription == "curl 'https://example.com' -X 'POST'")

    var streamed = makeRequest("https://example.com", method: "PUT")
    streamed.httpBodyStream = InputStream(data: Data(utf8: "x"))
    #expect(streamed.curlDescription == "curl 'https://example.com' -X 'PUT'")
  }
}
