import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Multipart form data")
struct MultipartTests {
  static let boundary = "----SwiftCURLBoundary7MA4YWxkTrZu0gW"

  static func body(_ parts: [(headers: [String], body: [UInt8])]) -> Data {
    var data = Data()
    for part in parts {
      data.append(Data(utf8: "--\(boundary)\r\n"))
      for header in part.headers { data.append(Data(utf8: header + "\r\n")) }
      data.append(Data(utf8: "\r\n"))
      data.append(contentsOf: part.body)
      data.append(Data(utf8: "\r\n"))
    }
    data.append(Data(utf8: "--\(boundary)--\r\n"))
    return data
  }

  static let textOnly = body([
    (["Content-Disposition: form-data; name=\"title\""], Array("it's $1".utf8)),
    (["Content-Disposition: form-data; name=\"note\""], Array("a;b=c\nline 2".utf8)),
  ])

  static let withFile = body([
    (["Content-Disposition: form-data; name=\"title\""], Array("Holiday".utf8)),
    (
      [
        "Content-Disposition: form-data; name=\"photo\"; filename=\"my \\\"pic\\\".png\"",
        "Content-Type: image/png",
      ],
      [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]
    ),
  ])

  static func request(_ body: Data) -> URLRequest {
    makeRequest(
      "https://example.com/upload", method: "POST",
      headers: [
        "Content-Type": "multipart/form-data; boundary=\(boundary)",
        "Content-Length": String(body.count),
      ],
      body: body)
  }

  @Test func rawIsDefaultAndByteExactForText() throws {
    let command = try Self.request(Self.textOnly).curlCommand()
    let text = String(decoding: Self.textOnly, as: UTF8.self)
    #expect(command.options.last == .dataRaw(text))
    #expect(
      command.options.contains(
        .header(name: "Content-Type", value: "multipart/form-data; boundary=\(Self.boundary)")))
    #expect(text.contains("\r\n"))
  }

  @Test func rawWithBinaryPartUsesPipeline() throws {
    let command = try Self.request(Self.withFile).curlCommand()
    #expect(command.standardInput?.data == Self.withFile)
    #expect(command.options.last == .dataBinary("@-"))
  }

  @Test func formFieldsTextOnly() throws {
    let command = try Self.request(Self.textOnly).curlCommand(
      options: .init { $0.multipartStrategy = .formFields(fileDirectory: nil) })
    #expect(
      command.options == [
        .formString("title=it's $1"),
        .formString("note=a;b=c\nline 2"),
      ])
    #expect(
      command.render()
        == "curl 'https://example.com/upload' --form-string 'title=it'\\''s $1'"
        + " --form-string 'note=a;b=c\nline 2'")
  }

  @Test func formFieldsWithFile() throws {
    let command = try Self.request(Self.withFile).curlCommand(
      options: .init { $0.multipartStrategy = .formFields(fileDirectory: "./uploads") })
    #expect(
      command.options == [
        .formString("title=Holiday"),
        .form(#"photo=@"./uploads/my \"pic\".png";filename="my \"pic\".png";type=image/png"#),
      ])
    #expect(command.standardInput == nil)
  }

  @Test func formFieldsWithPutKeepsMethod() throws {
    var request = Self.request(Self.textOnly)
    request.httpMethod = "PUT"
    let command = try request.curlCommand(
      options: .init { $0.multipartStrategy = .formFields(fileDirectory: nil) })
    #expect(command.options.first == .request("PUT"))
  }

  @Test func filenamePathTraversalIsStripped() throws {
    let body = Self.body([
      (
        ["Content-Disposition: form-data; name=\"f\"; filename=\"../../etc/passwd\""],
        Array("x".utf8)
      )
    ])
    let command = try Self.request(body).curlCommand(
      options: .init { $0.multipartStrategy = .formFields(fileDirectory: nil) })
    #expect(command.options == [.form(#"f=@"passwd";filename="../../etc/passwd""#)])
  }

  @Test func unrepresentablePartsFallBackToRaw() throws {
    let cases: [Data] = [
      // Non-text field without filename.
      Self.body([(["Content-Disposition: form-data; name=\"b\""], [0x00, 0x01])]),
      // Name containing '='.
      Self.body([(["Content-Disposition: form-data; name=\"a=b\""], Array("v".utf8))]),
      // Extra part header.
      Self.body([
        (
          ["Content-Disposition: form-data; name=\"a\"", "Content-Transfer-Encoding: 8bit"],
          Array("v".utf8)
        )
      ]),
      // Content type curl's -F cannot express.
      Self.body([
        (
          [
            "Content-Disposition: form-data; name=\"a\"; filename=\"a.txt\"",
            "Content-Type: text/plain; charset=utf-8",
          ],
          Array("v".utf8)
        )
      ]),
      // Non text/plain type on a plain field.
      Self.body([
        (["Content-Disposition: form-data; name=\"j\"", "Content-Type: application/json"], Array("{}".utf8))
      ]),
      // Garbage.
      Data(utf8: "not multipart at all"),
    ]
    for body in cases {
      let command = try Self.request(body).curlCommand(
        options: .init { $0.multipartStrategy = .formFields(fileDirectory: nil) })
      #expect(!command.options.contains { if case .form = $0 { true } else { false } })
      #expect(!command.options.contains { if case .formString = $0 { true } else { false } })
      #expect(command.options.contains { $0.sendsBody })
    }
  }

  @Test func boundaryParsing() {
    #expect(MultipartFormData.boundary(fromContentType: "multipart/form-data; boundary=abc") == "abc")
    #expect(
      MultipartFormData.boundary(fromContentType: #"Multipart/Form-Data; charset=utf-8; boundary="a b;c""#)
        == "a b;c")
    #expect(MultipartFormData.boundary(fromContentType: "multipart/mixed; boundary=abc") == nil)
    #expect(MultipartFormData.boundary(fromContentType: "multipart/form-data") == nil)
  }

  @Test func parserHandlesPreambleAndEmptyParts() throws {
    var data = Data(utf8: "preamble text\r\n")
    data.append(Self.body([(["Content-Disposition: form-data; name=\"empty\""], [])]))
    let parts = try #require(MultipartFormData.parse(Array(data), boundary: Self.boundary))
    #expect(parts.count == 1)
    #expect(parts[0].name == "empty")
    #expect(parts[0].body.isEmpty)
  }

  @Test func parserRejectsUnterminatedBody() {
    let data = Data(utf8: "--\(Self.boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue")
    #expect(MultipartFormData.parse(Array(data), boundary: Self.boundary) == nil)
  }
}
