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

    // Headers, sorted for deterministic output. Each name is lowercased once,
    // and each field copied to native UTF-8 once: on Apple platforms the
    // dictionary holds bridged strings, which are slow to read repeatedly.
    let headerFields = request.allHTTPHeaderFields ?? [:]
    let hasHeaders = !headerFields.isEmpty || !options.additionalCookies.isEmpty
    let excluded = hasHeaders ? Set(options.excludedHeaders.map { $0.lowercased() }) : []
    let redacted = hasHeaders ? Set(options.redactedHeaders.map { $0.lowercased() }) : []
    var headers: [(name: String, value: String)] = []
    var cookieValues: [String] = []
    var fields: [HeaderField] = []
    for (name, value) in headerFields {
      fields.append(HeaderField(name: name, value: value))
    }
    fields.sort(by: HeaderField.precedes)
    for field in fields {
      let (name, value, lowercased) = (field.name, field.value, field.lowercased)
      guard HTTPToken.isValid(name) else { throw .invalidHeaderName(name) }
      guard HTTPToken.isValidFieldValue(value) else { throw .invalidHeaderValue(name: name) }
      if excluded.contains(lowercased) { continue }
      if lowercased == "cookie" {
        cookieValues.append(value)
      } else {
        headers.append((name, redacted.contains(lowercased) ? options.redactionPlaceholder : value))
      }
    }

    // Body.
    let body = try resolveBody(of: request)
    let contentType = fields.first { $0.lowercased == "content-type" }?.value
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
    if !cookieValues.isEmpty, !excluded.contains("cookie") {
      var cookie = cookieValues.joined(separator: "; ")
      guard HTTPToken.isValidFieldValue(cookie) else { throw .invalidHeaderValue(name: "Cookie") }
      if redacted.contains("cookie") { cookie = options.redactionPlaceholder }
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

  private struct HeaderField {
    var name: String
    var value: String
    var lowercased: String

    init(name: String, value: String) {
      self.name = name.nativeUTF8
      self.value = value.nativeUTF8
      lowercased = self.name.lowercased()
    }

    /// Case-insensitive order, then case-sensitive for names equal but for case.
    static func precedes(_ lhs: HeaderField, _ rhs: HeaderField) -> Bool {
      lhs.lowercased == rhs.lowercased ? lhs.name < rhs.name : lhs.lowercased < rhs.lowercased
    }
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

  /// Rejects CR, LF and NUL, which would allow header injection. They are
  /// ASCII, so their bytes never appear inside a multi-byte scalar.
  static func isValidFieldValue(_ value: String) -> Bool {
    !value.utf8.contains { $0 == 13 || $0 == 10 || $0 == 0 }
  }
}

enum BodyText {
  /// Returns the body as a string when it is valid UTF-8 and contains no
  /// control characters other than tab, LF and CR. Anything else (including
  /// NUL, which no shell argument can carry, and terminal escape sequences)
  /// is treated as binary.
  static func text(from data: Data) -> String? {
    // C0 controls and DEL are single bytes; C1 controls (U+0080–U+009F) are
    // 0xC2 followed by 0x80–0x9F, and 0xC2 only ever leads a scalar. Binary
    // data usually fails here within a few bytes, before any decoding.
    let hasControl = data.withUnsafeBytes { bytes in
      var previous: UInt8 = 0
      for byte in bytes {
        switch byte {
        case 0x09, 0x0A, 0x0D: break
        case 0x00...0x1F, 0x7F: return true
        case 0x80...0x9F where previous == 0xC2: return true
        default: break
        }
        previous = byte
      }
      return false
    }
    return hasControl ? nil : String(strictUTF8: data)
  }
}
