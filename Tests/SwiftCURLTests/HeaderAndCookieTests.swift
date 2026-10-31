import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Headers")
struct HeaderTests {
  @Test func valueWithSingleQuotesColonsAndShellCharacters() throws {
    let request = makeRequest(
      "https://example.com",
      headers: ["X-Note": #"it's 10:30 — $PATH `id` "quoted" ; | & \ !"#])
    #expect(
      try request.curl()
        == #"curl 'https://example.com' -H 'X-Note: it'\''s 10:30 — $PATH `id` "quoted" ; | & \ !'"#
    )
  }

  @Test func emptyValueUsesSemicolonSyntax() throws {
    let request = makeRequest("https://example.com", headers: ["X-Empty": ""])
    let command = try request.curlCommand()
    #expect(command.options == [.header(name: "X-Empty", value: "")])
    #expect(command.render() == "curl 'https://example.com' -H 'X-Empty;'")
  }

  @Test(arguments: ["evil\r\nInjected: yes", "evil\nX: y", "nul\0byte", "cr\ronly"])
  func headerInjectionIsRejected(value: String) {
    let command = CURLConverter()
    var request = makeRequest("https://example.com")
    request.allHTTPHeaderFields = ["X-Test": value]
    // Some Foundation implementations already drop invalid values; if the
    // value survived, the converter must reject it.
    guard request.value(forHTTPHeaderField: "X-Test") != nil else { return }
    #expect(throws: CURLConversionError.invalidHeaderValue(name: "X-Test")) {
      try command.command(for: request)
    }
  }

  @Test(arguments: ["Bad Header", "Bad:Header", "Bad\"Header", "Bäd"])
  func invalidHeaderNamesAreRejected(name: String) {
    var request = makeRequest("https://example.com")
    request.allHTTPHeaderFields = [name: "v"]
    guard request.value(forHTTPHeaderField: name) != nil else { return }
    #expect(throws: CURLConversionError.invalidHeaderName(name)) { try request.curlCommand() }
  }

  @Test func redaction() throws {
    let request = makeRequest(
      "https://example.com",
      headers: ["Authorization": "Bearer secret", "X-Trace": "1", "Cookie": "sid=secret"])
    let options = CURLConversionOptions {
      $0.redactedHeaders = ["authorization", "COOKIE"]
      $0.redactionPlaceholder = "<redacted>"
    }
    #expect(
      try request.curl(options: options)
        == "curl 'https://example.com' -H 'Authorization: <redacted>' -H 'X-Trace: 1'"
        + " -H 'Cookie: <redacted>'")
  }

  @Test func loggingPresetRedactsCredentials() {
    let request = makeRequest(
      "https://example.com",
      headers: ["Authorization": "Basic dXNlcjpwYXNz", "Cookie": "sid=1", "Accept": "*/*"])
    #expect(
      request.curlDescription
        == "curl 'https://example.com' -H 'Accept: */*' -H 'Authorization: REDACTED'"
        + " -H 'Cookie: REDACTED'")
  }

  @Test func exclusion() throws {
    let request = makeRequest(
      "https://example.com", headers: ["User-Agent": "App/1.0", "Accept": "*/*"])
    let options = CURLConversionOptions { $0.excludedHeaders = ["user-agent"] }
    #expect(try request.curl(options: options) == "curl 'https://example.com' -H 'Accept: */*'")
  }

  @Test func longFlagStyle() throws {
    let request = makeRequest(
      "https://example.com", method: "PATCH",
      headers: ["Accept": "*/*", "Cookie": "a=1"], body: Data(utf8: "x"))
    let format = CURLRenderOptions(layout: .singleLine, flagStyle: .long)
    #expect(
      try request.curl(format: format)
        == "curl 'https://example.com' --request 'PATCH' --header 'Accept: */*'"
        + " --cookie 'a=1' --data-raw 'x'")
  }
}

@Suite("Cookies")
struct CookieTests {
  @Test func cookieHeaderBecomesCookieFlag() throws {
    let request = makeRequest(
      "https://example.com", headers: ["Cookie": "session=abc; theme=dark"])
    #expect(try request.curl() == "curl 'https://example.com' -b 'session=abc; theme=dark'")
  }

  @Test func cookieHeaderStrategy() throws {
    let request = makeRequest("https://example.com", headers: ["cookie": "session=abc"])
    let options = CURLConversionOptions { $0.cookieStrategy = .header }
    #expect(
      try request.curl(options: options) == "curl 'https://example.com' -H 'Cookie: session=abc'")
  }

  @Test func cookieWithoutEqualsNeverBecomesAFileName() throws {
    // `-b cookies.txt` would make curl read a local file.
    let request = makeRequest("https://example.com", headers: ["Cookie": "cookies.txt"])
    #expect(try request.curl() == "curl 'https://example.com' -H 'Cookie: cookies.txt'")
  }

  @Test func additionalCookiesAreMerged() throws {
    let request = makeRequest("https://example.com", headers: ["Cookie": "a=1"])
    let options = CURLConversionOptions {
      $0.additionalCookies = [CURLCookie(name: "b", value: "it's")]
    }
    #expect(try request.curl(options: options) == #"curl 'https://example.com' -b 'a=1; b=it'\''s'"#)
  }

  @Test func additionalCookiesAlone() throws {
    let request = makeRequest("https://example.com")
    let options = CURLConversionOptions { $0.additionalCookies = [.init(name: "x", value: "y")] }
    #expect(try request.curl(options: options) == "curl 'https://example.com' -b 'x=y'")
  }

  @Test func additionalCookieInjectionIsRejected() {
    let request = makeRequest("https://example.com")
    let options = CURLConversionOptions {
      $0.additionalCookies = [.init(name: "x", value: "y\r\nX-Evil: 1")]
    }
    #expect(throws: CURLConversionError.invalidHeaderValue(name: "Cookie")) {
      try request.curlCommand(options: options)
    }
  }

  @Test func excludedCookie() throws {
    let request = makeRequest("https://example.com", headers: ["Cookie": "a=1"])
    let options = CURLConversionOptions {
      $0.excludedHeaders = ["Cookie"]
      $0.additionalCookies = [.init(name: "b", value: "2")]
    }
    #expect(try request.curl(options: options) == "curl 'https://example.com'")
  }
}
