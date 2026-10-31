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
        if let pieces = Self.pieces(of: standardInput.data, substituting: format.substitutions) {
          // `{ printf … | base64 --decode; printf '%s' "$NAME"; …; }` writes the
          // same bytes, with each literal's bytes read from its variable.
          let parts = pieces.map { piece in
            switch piece {
            case .bytes(let bytes):
              "printf '%s' " + ShellEscaping.quote(Data(bytes).base64EncodedString())
                + " | base64 --decode"
            case .variable(let word):
              "printf '%s' " + word
            }
          }
          segments.append("{ " + parts.joined(separator: "; ") + "; }")
        } else {
          segments.append("printf '%s' " + ShellEscaping.quote(encoded))
          segments.append("| base64 --decode")
        }
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

  private enum Piece {
    case bytes([UInt8])
    /// A substitution's ``ShellSubstitution/shellWord``.
    case variable(String)
  }

  /// `data` cut where a substitution's literal (as UTF-8) appears, or `nil`
  /// when nothing matches. The longest literal wins, then the first given.
  private static func pieces(
    of data: Data?, substituting substitutions: [ShellSubstitution]
  ) -> [Piece]? {
    guard let data, !substitutions.isEmpty else { return nil }
    let bytes = [UInt8](data)
    let patterns = substitutions.map { (bytes: Array($0.literal.utf8), word: $0.shellWord) }
    var pieces: [Piece] = []
    var literal: [UInt8] = []
    var index = 0
    while index < bytes.count {
      var match: (length: Int, word: String)?
      for pattern in patterns
      where pattern.bytes.count > (match?.length ?? 0)
        && bytes.count - index >= pattern.bytes.count
        && bytes[index..<(index + pattern.bytes.count)].elementsEqual(pattern.bytes)
      {
        match = (pattern.bytes.count, pattern.word)
      }
      if let match {
        if !literal.isEmpty { pieces.append(.bytes(literal)) }
        literal = []
        pieces.append(.variable(match.word))
        index += match.length
      } else {
        literal.append(bytes[index])
        index += 1
      }
    }
    guard pieces.contains(where: { if case .variable = $0 { true } else { false } }) else {
      return nil
    }
    if !literal.isEmpty { pieces.append(.bytes(literal)) }
    return pieces
  }

  /// The single-line rendering of the command.
  public var description: String { render(.singleLine) }
}
