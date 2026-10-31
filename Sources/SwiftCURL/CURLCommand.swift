import Foundation

/// A strongly typed model of a `curl` invocation.
///
/// `CURLCommand` is the intermediate representation produced by
/// ``CURLConverter`` (or ``Foundation/URLRequest/curlCommand(options:)``).
/// It can be inspected, modified, and finally rendered to a shell command
/// string with ``render(_:)``.
///
/// ```swift
/// var command = try request.curlCommand()
/// command.options.append(.verbose)
/// print(command.render(.multiline))
/// ```
public struct CURLCommand: Sendable, Hashable, Codable, CustomStringConvertible {
  /// The executable name, `curl` by default.
  public var executable: String
  /// The target URL. It is always single-quoted when rendered.
  public var url: String
  /// The options, in the order they will be rendered (after the URL).
  public var options: [CURLOption]
  /// Data piped into curl's standard input (used with `--data-binary @-`).
  public var standardInput: StandardInput?

  /// Bytes that are piped into curl through a `printf … | base64 --decode`
  /// pipeline, so arbitrary binary data (including NUL bytes, which can
  /// never appear in a shell argument) survives the trip through the shell.
  public enum StandardInput: Sendable, Hashable, Codable {
    /// Base64-encoded payload, decoded with `base64 --decode` before curl
    /// reads it.
    case base64(String)

    /// Creates a base64 standard-input payload from raw bytes.
    public init(data: Data) {
      self = .base64(data.base64EncodedString())
    }

    /// The decoded bytes, or `nil` if the base64 payload is malformed.
    public var data: Data? {
      switch self {
      case .base64(let encoded): Data(base64Encoded: encoded)
      }
    }
  }

  public init(
    executable: String = "curl",
    url: String,
    options: [CURLOption] = [],
    standardInput: StandardInput? = nil
  ) {
    self.executable = executable
    self.url = url
    self.options = options
    self.standardInput = standardInput
  }

  /// The raw argument vector passed to curl (excluding the executable), i.e.
  /// exactly what curl receives in `argv[1...]` once the shell has removed
  /// the quoting.
  public func arguments(flagStyle: CURLOption.FlagStyle = .short) -> [String] {
    urlArguments + options.flatMap { $0.arguments(flagStyle: flagStyle) }
  }

  /// A URL that begins with `-` would be parsed by curl as an option, so it
  /// is passed through `--url` instead.
  private var urlArguments: [String] {
    url.hasPrefix("-") ? ["--url", url] : [url]
  }

  /// Renders the command as a shell string.
  public func render(_ format: CURLRenderOptions = .singleLine) -> String {
    let continuation: String
    switch format.layout {
    case .singleLine: continuation = " "
    case .multiline(let indentation): continuation = " \\\n" + indentation
    }

    var segments: [String] = []
    if let standardInput {
      switch standardInput {
      case .base64(let encoded):
        segments.append(
          "printf '%s' " + ShellEscaping.quote(encoded, substituting: format.substitutions))
        segments.append("| base64 --decode")
      }
      segments.append(
        "| " + ShellEscaping.quoteIfNeeded(executable) + " " + renderedURL(format))
    } else {
      segments.append(ShellEscaping.quoteIfNeeded(executable) + " " + renderedURL(format))
    }

    for option in options {
      let (flag, value) = option.components(flagStyle: format.flagStyle)
      var segment = ShellEscaping.isPlainFlag(flag) ? flag : ShellEscaping.quote(flag)
      if let value {
        segment += " " + ShellEscaping.quote(value, substituting: format.substitutions)
      }
      segments.append(segment)
    }
    return segments.joined(separator: continuation)
  }

  private func renderedURL(_ format: CURLRenderOptions) -> String {
    let quoted = ShellEscaping.quote(url, substituting: format.substitutions)
    return urlArguments.count == 2 ? "--url " + quoted : quoted
  }

  /// The single-line rendering of the command.
  public var description: String { render(.singleLine) }
}
