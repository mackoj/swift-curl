import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Converts a `URLRequest` into a ``CURLCommand``.
///
/// ```swift
/// let converter = CURLConverter(options: .logging)
/// let command = try converter.command(for: request)
/// print(command.render(.multiline))
/// ```
public struct CURLConverter: Sendable {
  public var options: CURLConversionOptions

  public init(options: CURLConversionOptions = .default) {
    self.options = options
  }

  /// Converts `request` into a ``CURLCommand``.
  public func command(for request: URLRequest) throws(CURLConversionError) -> CURLCommand {
    guard let url = request.url else { throw .missingURL }
    let urlString = url.absoluteString

    let method = request.httpMethod ?? "GET"
    guard HTTPToken.isValid(method) else { throw .invalidHTTPMethod(method) }

    // Headers, sorted for deterministic output.
    var headers: [(name: String, value: String)] = []
    var cookieValues: [String] = []
    let fields = (request.allHTTPHeaderFields ?? [:]).sorted {
      let lhs = $0.key.lowercased()
      let rhs = $1.key.lowercased()
      return lhs == rhs ? $0.key < $1.key : lhs < rhs
    }
    for (name, value) in fields {
      guard HTTPToken.isValid(name) else { throw .invalidHeaderName(name) }
      guard HTTPToken.isValidFieldValue(value) else { throw .invalidHeaderValue(name: name) }
      if options.isExcluded(name) { continue }
      if name.caseInsensitiveEquals("Cookie") {
        cookieValues.append(value)
      } else {
        headers.append((name, options.isRedacted(name) ? options.redactionPlaceholder : value))
      }
    }

    // Body.
    let body = try resolveBody(of: request)
    let contentType = fields.first { $0.key.caseInsensitiveEquals("Content-Type") }?.value
    let bodyPlan = try plan(body: body, method: method, contentType: contentType)
    if !bodyPlan.droppedHeaders.isEmpty {
      headers.removeAll { header in
        bodyPlan.droppedHeaders.contains { $0.caseInsensitiveEquals(header.name) }
      }
    }

    var result: [CURLOption] = []

    if urlString.contains(where: { "[]{}".contains($0) }) {
      result.append(.globOff)
    }

    // Method.
    let sendsBody = !bodyPlan.options.isEmpty
    if method == "HEAD" && !sendsBody {
      // `-X HEAD` makes curl wait for a body that never comes; `--head` is correct.
      result.append(.head)
    } else if options.alwaysIncludeMethod {
      result.append(.request(method))
    } else if sendsBody ? method != "POST" : method != "GET" {
      result.append(.request(method))
    }

    for header in headers {
      result.append(.header(name: header.name, value: header.value))
    }

    // Cookies.
    cookieValues.append(contentsOf: options.additionalCookies.map { "\($0.name)=\($0.value)" })
    if !cookieValues.isEmpty, !options.isExcluded("Cookie") {
      var cookie = cookieValues.joined(separator: "; ")
      guard HTTPToken.isValidFieldValue(cookie) else { throw .invalidHeaderValue(name: "Cookie") }
      if options.isRedacted("Cookie") { cookie = options.redactionPlaceholder }
      // Without `=` curl treats the `-b` argument as a cookie file name.
      if options.cookieStrategy == .cookieFlag && cookie.contains("=") {
        result.append(.cookie(cookie))
      } else {
        result.append(.header(name: "Cookie", value: cookie))
      }
    }

    result.append(contentsOf: bodyPlan.options)

    if options.followRedirects { result.append(.location) }
    if options.compressed { result.append(.compressed) }
    if options.includeTimeout { result.append(.maxTime(request.timeoutInterval)) }
    result.append(contentsOf: options.additionalOptions)

    return CURLCommand(
      executable: options.executable,
      url: urlString,
      options: result,
      standardInput: bodyPlan.standardInput
    )
  }

  // MARK: - Body

  private struct BodyPlan {
    var options: [CURLOption] = []
    var standardInput: CURLCommand.StandardInput?
    var droppedHeaders: [String] = []
  }

  private func resolveBody(of request: URLRequest) throws(CURLConversionError) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    switch options.bodyStreamStrategy {
    case .throwError: throw .bodyStreamNotSupported
    case .omit: return nil
    case .read(let maxLength): return try Self.read(stream, maxLength: maxLength)
    }
  }

  private static func read(_ stream: InputStream, maxLength: Int) throws(CURLConversionError) -> Data {
    if stream.streamStatus == .notOpen { stream.open() }
    defer { stream.close() }
    var data = Data()
    let chunkSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = stream.read(&buffer, maxLength: chunkSize)
      if count < 0 {
        throw .bodyStreamReadFailed(stream.streamError?.localizedDescription ?? "unknown error")
      }
      if count == 0 { break }
      data.append(contentsOf: buffer[0..<count])
      if data.count > max(maxLength, 0) { throw .bodyStreamTooLarge(limit: maxLength) }
    }
    return data
  }

  private func plan(
    body: Data?, method: String, contentType: String?
  ) throws(CURLConversionError) -> BodyPlan {
    guard let body else { return BodyPlan() }

    // An empty body is meaningful (Content-Length: 0) except for GET/HEAD,
    // where URLSession does not send it either.
    if body.isEmpty {
      if method == "GET" || method == "HEAD" { return BodyPlan() }
      return BodyPlan(options: [textOption("")])
    }

    if case .formFields(let directory) = options.multipartStrategy,
      let contentType,
      let formPlan = formFieldsPlan(body: body, contentType: contentType, directory: directory)
    {
      return formPlan
    }

    if let text = BodyText.text(from: body) {
      return BodyPlan(options: [textOption(text)])
    }

    switch options.binaryBodyStrategy {
    case .base64Pipeline:
      return BodyPlan(options: [.dataBinary("@-")], standardInput: .init(data: body))
    case .file(let path):
      return BodyPlan(options: [.dataBinary("@" + path)])
    case .omit:
      return BodyPlan()
    case .throwError:
      throw .binaryBodyNotAllowed(byteCount: body.count)
    }
  }

  private func textOption(_ text: String) -> CURLOption {
    // `@` at the start of `-d` / `--data-binary` means "read this file".
    if text.hasPrefix("@") { return .dataRaw(text) }
    switch options.textBodyFlag {
    case .dataRaw: return .dataRaw(text)
    case .data: return .data(text)
    case .dataBinary: return .dataBinary(text)
    }
  }

  private func formFieldsPlan(body: Data, contentType: String, directory: String?) -> BodyPlan? {
    guard let boundary = MultipartFormData.boundary(fromContentType: contentType),
      let parts = MultipartFormData.parse(Array(body), boundary: boundary)
    else { return nil }

    var formOptions: [CURLOption] = []
    for part in parts {
      // `name=value` is split on the first `=`.
      guard part.otherHeaders.isEmpty, !part.name.isEmpty, !part.name.contains("=") else {
        return nil
      }
      if let filename = part.filename {
        guard let option = fileFormOption(part: part, filename: filename, directory: directory)
        else { return nil }
        formOptions.append(option)
      } else {
        guard let text = BodyText.text(from: Data(part.body)) else { return nil }
        if let type = part.contentType, !type.lowercased().hasPrefix("text/plain") {
          return nil
        }
        formOptions.append(.formString("\(part.name)=\(text)"))
      }
    }
    return BodyPlan(options: formOptions, droppedHeaders: ["Content-Type", "Content-Length"])
  }

  private func fileFormOption(
    part: MultipartFormData.Part, filename: String, directory: String?
  ) -> CURLOption? {
    // Only the last path component is used to build the local path.
    let component =
      filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    guard !component.isEmpty, component != ".", component != "..",
      HTTPToken.isValidFieldValue(filename)
    else { return nil }

    let path: String
    if let directory, !directory.isEmpty {
      path = directory.hasSuffix("/") ? directory + component : directory + "/" + component
    } else {
      path = component
    }

    var value = "\(part.name)=@\(Self.formQuoted(path));filename=\(Self.formQuoted(filename))"
    if let type = part.contentType {
      // curl's `type=` parser does not support quoting; reject what it can't express.
      guard !type.contains(where: { ";,\"".contains($0) }), HTTPToken.isValidFieldValue(type)
      else { return nil }
      value += ";type=\(type)"
    }
    return .form(value)
  }

  /// Double-quotes a value for curl's `-F` mini-language (`\` and `"` escaped).
  private static func formQuoted(_ value: String) -> String {
    var result = "\""
    for character in value {
      if character == "\\" || character == "\"" { result.append("\\") }
      result.append(character)
    }
    return result + "\""
  }
}

// MARK: - Validation helpers

enum HTTPToken {
  /// RFC 9110 `token`: 1*tchar.
  static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9": true
      case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~": true
      default: false
      }
    }
  }

  /// Rejects CR, LF and NUL, which would allow header injection.
  static func isValidFieldValue(_ value: String) -> Bool {
    !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
  }
}

enum BodyText {
  /// Returns the body as a string when it is valid UTF-8 and contains no
  /// control characters other than tab, LF and CR. Anything else (including
  /// NUL, which no shell argument can carry, and terminal escape sequences)
  /// is treated as binary.
  static func text(from data: Data) -> String? {
    guard let text = String(strictUTF8: data) else { return nil }
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x09, 0x0A, 0x0D: continue
      case 0x00...0x1F, 0x7F...0x9F: return nil
      default: continue
      }
    }
    return text
  }
}
