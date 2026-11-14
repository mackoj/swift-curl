import Benchmark
import Foundation
import SwiftCURL

/// Inputs shared by the benchmarks. Built once, outside the measured closures.
enum Fixtures {
  static let token = "s3cr3t-0123456789abcdef"

  /// A plain GET with no headers and no body.
  static let simpleGET = URLRequest(
    url: URL(string: "https://api.example.com/v1/users?page=2&per_page=50")!)

  /// A POST with 50 headers (credentials included), a cookie and a small JSON body: a typical API call, logged.
  static let manyHeaders: URLRequest = {
    var request = URLRequest(url: URL(string: "https://api.example.com/v1/orders")!)
    request.httpMethod = "POST"
    for index in 0..<45 {
      request.setValue("value-\(index); q=0.\(index % 10)", forHTTPHeaderField: "X-Custom-\(index)")
    }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("session=abc; theme=dark", forHTTPHeaderField: "Cookie")
    request.setValue(token, forHTTPHeaderField: "X-API-Key")
    request.httpBody = Data(#"{"item":"O'Brien's book","quantity":2}"#.utf8)
    return request
  }()

  /// About 1 MB of JSON text with single quotes, `$`, backticks and non-ASCII text.
  static let jsonText: String = {
    let record =
      #"{"id":%d,"name":"O'Brien été 中文","note":"costs $5 `now`","tags":["a","b"]},"#
    let records = (0..<10_000).map { String(format: record, $0) }
    return "[" + records.joined() + "{}]"
  }()

  static let jsonBody: URLRequest = {
    var request = URLRequest(url: URL(string: "https://api.example.com/v1/import")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(jsonText.utf8)
    return request
  }()

  /// 1 MB of pseudo-random bytes: binary, so it is piped through base64.
  static let binaryData: Data = {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    return Data(
      (0..<1_000_000).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
      })
  }()

  static let binaryBody: URLRequest = {
    var request = URLRequest(url: URL(string: "https://api.example.com/v1/upload")!)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = binaryData
    return request
  }()

  /// A 64 KB binary body with the token's bytes in it every 4 KB, for substitution inside a piped body.
  static let binaryWithToken: URLRequest = {
    var bytes = [UInt8](binaryData.prefix(64 * 1024))
    for offset in stride(from: 1024, to: bytes.count - 64, by: 4096) {
      bytes.replaceSubrange(offset..<(offset + token.utf8.count), with: Array(token.utf8))
    }
    var request = binaryBody
    request.httpBody = Data(bytes)
    return request
  }()

  /// Adversarial text, 64 KB: every shell metacharacter, quotes of both kinds, newlines and Unicode.
  static let adversarial: String = {
    let pieces = [
      "'", "''", #"'\''"#, "\"", "$HOME", "${PATH}", "$(touch /tmp/x)", "`id`", "!!", "\\",
      "a;b|c&d", "> /x < /y",
      "*", "~", "#c", "\n", "\r\n", "\t", "é ü 中文 😀", "-X DELETE", "%s%n",
    ]
    var text = ""
    var index = 0
    while text.utf8.count < 64 * 1024 {
      text += pieces[index % pieces.count] + "x"
      index += 1
    }
    return text
  }()

  /// A request carrying the token raw, base64-encoded (Basic auth) and percent-encoded (query).
  static let encodedSubstitutionRequest: URLRequest = {
    let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    var request = URLRequest(
      url: URL(string: "https://api.example.com/v1/search?key=\(encoded)&q=it%27s")!)
    request.setValue(
      "Basic " + Data("user:\(token)".utf8).base64EncodedString(),
      forHTTPHeaderField: "Authorization")
    request.setValue(token, forHTTPHeaderField: "X-API-Key")
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"token":"\#(token)","note":"it's"}"#.utf8)
    return request
  }()

  static let encodedSubstitutions: [ShellSubstitution] = [
    ShellSubstitution(literal: token, variable: "API_TOKEN")!,
    ShellSubstitution(
      literal: Data("user:\(token)".utf8).base64EncodedString(), variable: "BASIC",
      encoding: .base64)!,
    ShellSubstitution(
      literal: token.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
      variable: "API_TOKEN",
      encoding: .percentEncoded)!,
  ]

  static let tokenSubstitution = [ShellSubstitution(literal: token, variable: "API_TOKEN")!]
}

let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = .init(
    metrics: [.wallClock, .cpuTotal, .mallocCountTotal, .peakMemoryResident, .retainCount],
    // Exact counts and microseconds, so a change of a few percent shows up in a comparison.
    timeUnits: .microseconds,
    units: [.mallocCountTotal: .count, .retainCount: .count],
    maxDuration: .seconds(2),
    maxIterations: 1_000
  )
  let perOperation = Benchmark.Configuration(timeUnits: .nanoseconds, scalingFactor: .kilo)

  // MARK: Conversion and rendering

  let simpleGET = Fixtures.simpleGET
  Benchmark("curl(), simple GET", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations { blackHole(try simpleGET.curl()) }
  }

  Benchmark("curlDescription, simple GET", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations { blackHole(simpleGET.curlDescription) }
  }

  let manyHeaders = Fixtures.manyHeaders
  Benchmark("curl(), 50 headers") { benchmark in
    for _ in 0..<100 { blackHole(try manyHeaders.curl(format: .multiline)) }
  }

  Benchmark("curlDescription, 50 headers (logging preset)") { benchmark in
    for _ in 0..<100 { blackHole(manyHeaders.curlDescription) }
  }

  let jsonBody = Fixtures.jsonBody
  Benchmark("curl(), 1 MB JSON body") { benchmark in
    blackHole(try jsonBody.curl())
  }

  let jsonCommand = try! jsonBody.curlCommand()
  Benchmark("Render, 1 MB JSON body") { benchmark in
    blackHole(jsonCommand.render())
  }

  let binaryBody = Fixtures.binaryBody
  Benchmark("curl(), 1 MB binary body") { benchmark in
    blackHole(try binaryBody.curl())
  }

  let binaryCommand = try! binaryBody.curlCommand()
  Benchmark("Render, 1 MB binary body") { benchmark in
    blackHole(binaryCommand.render())
  }

  // MARK: Quoting

  let adversarial = Fixtures.adversarial
  Benchmark("ShellEscaping.quote, 64 KB adversarial") { benchmark in
    blackHole(ShellEscaping.quote(adversarial))
  }

  let shortValues = ["application/json", "Bearer abc.def.ghi", "it's", "", "$(id)", "é ü 中文 😀"]
  Benchmark("ShellEscaping.quote, short values", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      for value in shortValues { blackHole(ShellEscaping.quote(value)) }
    }
  }

  // MARK: Substitutions

  let tokenText = Fixtures.adversarial + Fixtures.token + Fixtures.adversarial
  Benchmark("quote(substituting:), 128 KB, one match") { benchmark in
    blackHole(ShellEscaping.quote(tokenText, substituting: Fixtures.encodedSubstitutions))
  }

  Benchmark("quote(substituting:), 64 KB, no match") { benchmark in
    blackHole(ShellEscaping.quote(adversarial, substituting: Fixtures.tokenSubstitution))
  }

  let encodedCommand = try! Fixtures.encodedSubstitutionRequest.curlCommand()
  let encodedFormat = CURLRenderOptions(
    layout: .multiline(indentation: "  "), substitutions: Fixtures.encodedSubstitutions)
  Benchmark("Render, encoded substitutions", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations { blackHole(encodedCommand.render(encodedFormat)) }
  }

  let jsonFormat = CURLRenderOptions(substitutions: Fixtures.tokenSubstitution)
  Benchmark("Render, 1 MB JSON body, substitution") { benchmark in
    blackHole(jsonCommand.render(jsonFormat))
  }

  let binaryWithToken = try! Fixtures.binaryWithToken.curlCommand()
  Benchmark("Render, 64 KB binary body, substitution") { benchmark in
    blackHole(binaryWithToken.render(jsonFormat))
  }
}
