import Foundation

/// Minimal, defensive parser for `multipart/form-data` bodies (RFC 7578).
enum MultipartFormData {
  struct Part: Equatable {
    var name: String
    var filename: String?
    var contentType: String?
    /// Header names other than Content-Disposition / Content-Type.
    var otherHeaders: [String]
    var body: [UInt8]
  }

  /// Extracts the boundary from a `multipart/form-data` Content-Type value.
  static func boundary(fromContentType contentType: String) -> String? {
    let parameters = HeaderParameters.parse(contentType)
    guard parameters.value.lowercased() == "multipart/form-data",
      let boundary = parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 200
    else { return nil }
    return boundary
  }

  /// Parses `body`. Returns `nil` if it is not well-formed.
  static func parse(_ body: [UInt8], boundary: String) -> [Part]? {
    let delimiter = Array("--\(boundary)".utf8)
    let crlf: [UInt8] = [13, 10]

    // The first delimiter must start the body (optionally after a preamble
    // ending in CRLF).
    var cursor: Int
    if body.starts(with: delimiter) {
      cursor = delimiter.count
    } else if let index = body.rangeOfBytes(crlf + delimiter) {
      cursor = index.upperBound
    } else {
      return nil
    }

    var parts: [Part] = []
    while true {
      // After a delimiter: either "--" (close) or CRLF (next part).
      if body[cursor...].starts(with: [45, 45]) { break }
      // Transport padding (spaces/tabs) is allowed before CRLF.
      while cursor < body.count, body[cursor] == 32 || body[cursor] == 9 { cursor += 1 }
      guard body[cursor...].starts(with: crlf) else { return nil }
      cursor += 2

      guard let next = body[cursor...].rangeOfBytes(crlf + delimiter) else { return nil }
      guard let part = parsePart(Array(body[cursor..<next.lowerBound])) else { return nil }
      parts.append(part)
      cursor = next.upperBound
    }
    return parts.isEmpty ? nil : parts
  }

  private static func parsePart(_ bytes: [UInt8]) -> Part? {
    let separator: [UInt8] = [13, 10, 13, 10]
    let headerBytes: [UInt8]
    let body: [UInt8]
    if bytes.starts(with: [13, 10]) {
      headerBytes = []
      body = Array(bytes.dropFirst(2))
    } else if let range = bytes.rangeOfBytes(separator) {
      headerBytes = Array(bytes[..<range.lowerBound])
      body = Array(bytes[range.upperBound...])
    } else {
      return nil
    }

    guard let headerText = String(strictUTF8: headerBytes) else { return nil }
    var name: String?
    var filename: String?
    var contentType: String?
    var otherHeaders: [String] = []

    for line in headerText.components(separatedBy: "\r\n") where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let field = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      switch field.lowercased() {
      case "content-disposition":
        let parameters = HeaderParameters.parse(value)
        guard parameters.value.lowercased() == "form-data" else { return nil }
        name = parameters["name"]
        filename = parameters["filename"]
      case "content-type":
        contentType = value
      default:
        otherHeaders.append(field)
      }
    }
    guard let name else { return nil }
    return Part(
      name: name, filename: filename, contentType: contentType,
      otherHeaders: otherHeaders, body: body)
  }
}

/// Parses `value; key=token; key="quoted \"string\""` header values.
struct HeaderParameters {
  var value: String
  var parameters: [String: String]

  subscript(key: String) -> String? { parameters[key.lowercased()] }

  static func parse(_ header: String) -> HeaderParameters {
    var segments: [String] = []
    var current = ""
    var inQuotes = false
    var escaped = false
    for character in header {
      if escaped {
        current.append(character)
        escaped = false
      } else if inQuotes && character == "\\" {
        current.append(character)
        escaped = true
      } else if character == "\"" {
        current.append(character)
        inQuotes.toggle()
      } else if character == ";" && !inQuotes {
        segments.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    segments.append(current)

    let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""
    var parameters: [String: String] = [:]
    for segment in segments.dropFirst() {
      guard let equals = segment.firstIndex(of: "=") else { continue }
      let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      var raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
        raw = unescapeQuoted(String(raw.dropFirst().dropLast()))
      }
      if parameters[key] == nil { parameters[key] = raw }
    }
    return HeaderParameters(value: value, parameters: parameters)
  }

  private static func unescapeQuoted(_ value: String) -> String {
    var result = ""
    var escaped = false
    for character in value {
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else {
        result.append(character)
      }
    }
    return result
  }
}

extension String {
  /// Strict UTF-8 decoding that works on every supported platform.
  init?<Bytes: Collection>(strictUTF8 bytes: Bytes) where Bytes.Element == UInt8 {
    let decoded = String(decoding: bytes, as: UTF8.self)
    guard decoded.utf8.elementsEqual(bytes) else { return nil }
    self = decoded
  }
}

extension Collection where Element: Equatable, Index == Int {
  /// Naive subsequence search (bodies handled here are small).
  func rangeOfBytes(_ pattern: [Element]) -> Range<Int>? {
    guard !pattern.isEmpty, count >= pattern.count else { return nil }
    var index = startIndex
    let last = endIndex - pattern.count
    while index <= last {
      if self[index] == pattern[0],
        self[index..<(index + pattern.count)].elementsEqual(pattern)
      {
        return index..<(index + pattern.count)
      }
      index += 1
    }
    return nil
  }
}
