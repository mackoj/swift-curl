import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Basic requests & methods")
struct BasicRequestTests {
  @Test func simpleGet() throws {
    let request = makeRequest("https://example.com/path")
    #expect(try request.curl() == "curl 'https://example.com/path'")
  }

  @Test func getWithQueryParametersAndHeaders() throws {
    let request = makeRequest(
      "https://api.example.com/search?q=swift&page=2&sort=desc",
      headers: ["Accept": "application/json", "Authorization": "Bearer abc.def"]
    )
    #expect(
      try request.curl()
        == "curl 'https://api.example.com/search?q=swift&page=2&sort=desc'"
        + " -H 'Accept: application/json' -H 'Authorization: Bearer abc.def'")
  }

  @Test func headersAreSortedCaseInsensitively() throws {
    let request = makeRequest(
      "https://example.com", headers: ["b-header": "2", "A-Header": "1", "c": "3"])
    let names = try request.curlCommand().options.compactMap { option -> String? in
      if case .header(let name, _) = option { return name }
      return nil
    }
    // Foundation may canonicalise the casing of header names.
    #expect(names.map { $0.lowercased() } == ["a-header", "b-header", "c"])
  }

  @Test func redundantGetIsOmitted() throws {
    let request = makeRequest("https://example.com", method: "GET")
    #expect(!(try request.curl()).contains("-X"))
  }

  @Test func alwaysIncludeMethod() throws {
    let request = makeRequest("https://example.com", method: "GET")
    let options = CURLConversionOptions { $0.alwaysIncludeMethod = true }
    #expect(try request.curl(options: options) == "curl 'https://example.com' -X 'GET'")
  }

  @Test(arguments: ["PUT", "DELETE", "PATCH", "OPTIONS", "POST"])
  func standardMethodsWithoutBody(method: String) throws {
    let request = makeRequest("https://example.com/r/1", method: method)
    #expect(try request.curl() == "curl 'https://example.com/r/1' -X '\(method)'")
  }

  @Test func postWithBodyOmitsMethod() throws {
    let request = makeRequest("https://example.com", method: "POST", body: Data(utf8: "a=1"))
    #expect(try request.curl() == "curl 'https://example.com' --data-raw 'a=1'")
  }

  @Test(arguments: ["PUT", "PATCH", "DELETE"])
  func nonPostWithBodyKeepsMethod(method: String) throws {
    let request = makeRequest("https://example.com", method: method, body: Data(utf8: "x"))
    #expect(try request.curl() == "curl 'https://example.com' -X '\(method)' --data-raw 'x'")
  }

  @Test func getWithBodyRequiresExplicitMethod() throws {
    // `--data-raw` alone would turn the request into a POST.
    let request = makeRequest("https://example.com", method: "GET", body: Data(utf8: "q"))
    #expect(try request.curl() == "curl 'https://example.com' -X 'GET' --data-raw 'q'")
  }

  @Test func headUsesHeadFlag() throws {
    let request = makeRequest("https://example.com", method: "HEAD")
    #expect(try request.curl() == "curl 'https://example.com' -I")
    let options = CURLConversionOptions { $0.alwaysIncludeMethod = true }
    #expect(try request.curl(options: options) == "curl 'https://example.com' -I")
  }

  @Test(arguments: ["PROPFIND", "MKCOL", "PURGE", "LINK", "post", "X-Custom.Verb_1"])
  func customVerbs(method: String) throws {
    let request = makeRequest("https://example.com", method: method)
    // Some Foundation versions upper-case well-known verbs ("post" → "POST").
    let effective = try #require(request.httpMethod)
    #expect(effective.uppercased() == method.uppercased())
    #expect(try request.curl() == "curl 'https://example.com' -X '\(effective)'")
  }

  @Test(arguments: ["GET /evil HTTP/1.1\r\nHost: x", "GE T", "GET\n", "GÉT", "$(id)"])
  func invalidMethodsAreRejected(method: String) {
    let request = makeRequest("https://example.com", method: method)
    #expect(throws: CURLConversionError.invalidHTTPMethod(method)) {
      try request.curlCommand()
    }
  }

  @Test func missingURL() {
    var request = makeRequest("https://example.com")
    request.url = nil
    #expect(throws: CURLConversionError.missingURL) { try request.curlCommand() }
    #expect(request.curlDescription == "# curl conversion failed: The request has no URL.")
  }

  @Test func urlWithSingleQuoteAndShellCharacters() throws {
    // All of these are legal, unencoded URL sub-delimiters.
    let request = makeRequest("https://example.com/it's?a=$HOME&b=(x)&c=!x;rm*")
    #expect(try request.curl() == #"curl 'https://example.com/it'\''s?a=$HOME&b=(x)&c=!x;rm*'"#)
  }

  @Test func urlWithBracketsDisablesGlobbing() throws {
    let request = makeRequest("http://[::1]:8080/items")
    #expect(try request.curl() == "curl 'http://[::1]:8080/items' -g")
    let plain = makeRequest("https://example.com/a")
    #expect(!(try plain.curlCommand()).options.contains(.globOff))
  }

  @Test func behaviourFlags() throws {
    var request = makeRequest("https://example.com")
    request.timeoutInterval = 12.5
    let options = CURLConversionOptions {
      $0.followRedirects = true
      $0.compressed = true
      $0.includeTimeout = true
      $0.additionalOptions = [.verbose, .custom(flag: "--retry", value: "3")]
    }
    #expect(
      try request.curl(options: options)
        == "curl 'https://example.com' -L --compressed -m '12.5' -v --retry '3'")
  }

  @Test func customExecutable() throws {
    let request = makeRequest("https://example.com")
    let options = CURLConversionOptions { $0.executable = "/opt/curl 8/bin/curl" }
    #expect(try request.curl(options: options) == "'/opt/curl 8/bin/curl' 'https://example.com'")
  }
}
