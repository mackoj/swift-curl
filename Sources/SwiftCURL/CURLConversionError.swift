/// Errors thrown while converting a `URLRequest` into a ``CURLCommand``.
public enum CURLConversionError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The request has no URL.
  case missingURL
  /// The HTTP method is empty or contains characters outside the RFC 9110
  /// token set (e.g. whitespace or CR/LF, which would allow request smuggling).
  case invalidHTTPMethod(String)
  /// A header name is empty or contains characters outside the RFC 9110
  /// token set.
  case invalidHeaderName(String)
  /// A header value contains CR, LF or NUL, which would allow header injection.
  case invalidHeaderValue(name: String)
  /// The body is binary and ``CURLConversionOptions/BinaryBodyStrategy/throwError``
  /// was requested.
  case binaryBodyNotAllowed(byteCount: Int)
  /// The request uses `httpBodyStream` and
  /// ``CURLConversionOptions/BodyStreamStrategy/throwError`` was requested.
  case bodyStreamNotSupported
  /// The body stream produced more than the configured number of bytes.
  case bodyStreamTooLarge(limit: Int)
  /// Reading the body stream failed.
  case bodyStreamReadFailed(String)

  public var description: String {
    switch self {
    case .missingURL:
      "The request has no URL."
    case .invalidHTTPMethod(let method):
      "Invalid HTTP method \(String(reflecting: method))."
    case .invalidHeaderName(let name):
      "Invalid HTTP header name \(String(reflecting: name))."
    case .invalidHeaderValue(let name):
      "The value of HTTP header \(String(reflecting: name)) contains CR, LF or NUL."
    case .binaryBodyNotAllowed(let count):
      "The request body is binary (\(count) bytes) and binary bodies are not allowed."
    case .bodyStreamNotSupported:
      "The request uses httpBodyStream, which is not supported by the current options."
    case .bodyStreamTooLarge(let limit):
      "The request body stream exceeds the \(limit)-byte limit."
    case .bodyStreamReadFailed(let reason):
      "Reading the request body stream failed: \(reason)"
    }
  }
}
