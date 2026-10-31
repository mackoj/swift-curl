/// Options controlling how a `URLRequest` is converted into a ``CURLCommand``.
public struct CURLConversionOptions: Sendable, Hashable {
  // MARK: - Nested types

  /// Which curl flag carries a textual (UTF-8) body.
  public enum TextBodyFlag: String, Sendable, Hashable, CaseIterable {
    /// `--data-raw`: sent verbatim, `@` is not special. Recommended.
    case dataRaw
    /// `-d / --data`. Bodies starting with `@` (which curl would treat as a
    /// file name) automatically fall back to `--data-raw`.
    case data
    /// `--data-binary`. Bodies starting with `@` automatically fall back to
    /// `--data-raw`.
    case dataBinary
  }

  /// How a binary body (non-UTF-8, or containing control characters such as
  /// NUL that cannot be represented safely in a shell argument) is handled.
  public enum BinaryBodyStrategy: Sendable, Hashable {
    /// Pipe the bytes into curl through
    /// `printf '%s' '<base64>' | base64 --decode | curl … --data-binary @-`.
    /// Byte-exact and self-contained.
    case base64Pipeline
    /// Reference a local file holding the body: `--data-binary @<path>`.
    case file(path: String)
    /// Drop the body. The resulting command is *not* faithful.
    case omit
    /// Throw ``CURLConversionError/binaryBodyNotAllowed(byteCount:)``.
    case throwError
  }

  /// How a request whose body is provided through `httpBodyStream` is handled.
  public enum BodyStreamStrategy: Sendable, Hashable {
    /// Throw ``CURLConversionError/bodyStreamNotSupported``.
    case throwError
    /// Ignore the stream. The resulting command is *not* faithful.
    case omit
    /// Read the stream (at most `maxLength` bytes) and treat the bytes like
    /// `httpBody`.
    ///
    /// - Important: Streams cannot be rewound. Reading consumes the stream,
    ///   so the original `URLRequest` must not be sent afterwards.
    case read(maxLength: Int)
  }

  /// How `multipart/form-data` bodies are represented.
  public enum MultipartStrategy: Sendable, Hashable {
    /// Send the body bytes exactly as encoded, keeping the request's
    /// `Content-Type` header (and therefore its boundary). Byte-exact.
    case raw
    /// Re-express each part as a curl form field: text fields become
    /// `--form-string 'name=value'`; file parts become
    /// `-F 'name=@"<directory>/<filename>";filename="<filename>";type=<type>'`,
    /// which expects the file to exist locally. curl generates its own
    /// boundary, so `Content-Type` and `Content-Length` headers are dropped.
    ///
    /// Falls back to ``raw`` whenever the body cannot be parsed or a part
    /// cannot be represented faithfully as a curl form field.
    case formFields(fileDirectory: String?)
  }

  /// How the `Cookie` header is emitted.
  public enum CookieStrategy: String, Sendable, Hashable, CaseIterable {
    /// `-b 'name=value; other=value'`. Falls back to ``header`` when the
    /// value contains no `=` (curl would otherwise read it as a file name).
    case cookieFlag
    /// `-H 'Cookie: name=value'`.
    case header
  }

  // MARK: - Properties

  /// Executable name used in the rendered command.
  public var executable: String = "curl"
  /// Always emit `-X <method>`, even when curl would infer the method.
  public var alwaysIncludeMethod: Bool = false
  /// Flag used for textual bodies.
  public var textBodyFlag: TextBodyFlag = .dataRaw
  /// Handling of binary bodies.
  public var binaryBodyStrategy: BinaryBodyStrategy = .base64Pipeline
  /// Handling of `httpBodyStream`.
  public var bodyStreamStrategy: BodyStreamStrategy = .throwError
  /// Handling of `multipart/form-data` bodies.
  public var multipartStrategy: MultipartStrategy = .raw
  /// Handling of the `Cookie` header.
  public var cookieStrategy: CookieStrategy = .cookieFlag
  /// Extra cookies merged after the request's own `Cookie` header.
  public var additionalCookies: [CURLCookie] = []
  /// Header names (case-insensitive) that are not emitted at all.
  public var excludedHeaders: Set<String> = []
  /// Header names (case-insensitive) whose values are replaced with
  /// ``redactionPlaceholder``. Including `Cookie` also redacts `-b`.
  public var redactedHeaders: Set<String> = []
  /// Replacement for redacted header values.
  public var redactionPlaceholder: String = "REDACTED"
  /// Emit `-L` (URLSession follows redirects by default; curl does not).
  public var followRedirects: Bool = false
  /// Emit `--compressed` (URLSession transparently decompresses responses).
  public var compressed: Bool = false
  /// Emit `--max-time <request.timeoutInterval>`.
  public var includeTimeout: Bool = false
  /// Options appended after everything derived from the request.
  public var additionalOptions: [CURLOption] = []

  public init() {}

  public init(_ configure: (inout CURLConversionOptions) -> Void) {
    configure(&self)
  }

  // MARK: - Presets

  /// Faithful, byte-exact conversion.
  public static let `default` = CURLConversionOptions()

  /// Safe for logs: redacts credentials, omits binary and streamed bodies.
  public static let logging = CURLConversionOptions {
    $0.redactedHeaders = [
      "Authorization", "Proxy-Authorization", "Cookie", "X-API-Key", "X-Auth-Token",
    ]
    $0.binaryBodyStrategy = .omit
    $0.bodyStreamStrategy = .omit
  }

  // MARK: - Helpers

  func isExcluded(_ header: String) -> Bool {
    excludedHeaders.contains { $0.caseInsensitiveEquals(header) }
  }

  func isRedacted(_ header: String) -> Bool {
    redactedHeaders.contains { $0.caseInsensitiveEquals(header) }
  }
}

/// A cookie name/value pair passed through ``CURLConversionOptions/additionalCookies``.
public struct CURLCookie: Sendable, Hashable, Codable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

extension String {
  func caseInsensitiveEquals(_ other: String) -> Bool {
    lowercased() == other.lowercased()
  }
}
