/// Replaces every occurrence of a literal string in a rendered value with a
/// reference to a shell variable, written as `"$NAME"`.
///
/// Use it to keep secrets out of a command you hand to someone: the value is
/// never written, and the command still runs once the variable is set.
///
/// ```swift
/// let token = ShellSubstitution(literal: "s3cr3t", variable: "API_TOKEN")!
/// command.render(.init(substitutions: [token]))
/// // curl 'https://api.example.com' -H 'Authorization: Bearer '"$API_TOKEN"
/// ```
///
/// The literal parts stay single-quoted and the reference is double-quoted, so
/// the shell neither splits nor globs the variable's value. With the variable
/// set to `literal`, curl receives exactly ``CURLCommand/arguments(flagStyle:)``.
///
/// When the request carries a value in an encoded spelling (HTTP Basic's
/// base64, a percent-encoded query parameter), give the encoded spelling as the
/// literal and its ``Encoding``: the command then computes the same encoded
/// text from the variable, which holds the plain value.
///
/// ```swift
/// let token = ShellSubstitution(literal: "czNjcjN0", variable: "API_TOKEN", encoding: .base64)!
/// // … '"$(printf %s "$API_TOKEN" | base64 | tr -d '\n')"'
/// ```
public struct ShellSubstitution: Sendable, Hashable, Codable {
  /// How the variable's value is turned into the text that replaces the
  /// literal. Each case is a fixed shell pipeline over `"$NAME"`, built only
  /// from POSIX tools (`printf`, `base64`, `tr`, `od`, `awk`); none takes free
  /// text, so a substitution can't inject shell code.
  public enum Encoding: String, Sendable, Hashable, Codable, CaseIterable {
    /// The value as is: `"$NAME"`.
    case raw
    /// Standard base64 with padding (RFC 4648 §4) of the value's bytes, on
    /// one line: `"$(printf %s "$NAME" | base64 | tr -d '\n')"`. `tr` removes
    /// the line breaks GNU `base64` adds every 76 characters.
    case base64
    /// Percent-encoding of the value's bytes, keeping only RFC 3986
    /// unreserved characters (`A–Z a–z 0–9 - . _ ~`) and writing every other
    /// byte as `%XX` with uppercase hex, as Foundation's
    /// `addingPercentEncoding(withAllowedCharacters:)` does with that set.
    /// The bytes go through `od` and `awk`, with no other tool needed.
    case percentEncoded
  }

  /// The text to replace. Never empty, and never contains NUL (no shell
  /// variable can hold it).
  public let literal: String
  /// The shell variable written in its place. A POSIX name: `[A-Za-z_][A-Za-z0-9_]*`.
  public let variable: String
  /// How `literal` is computed from the variable's value. ``Encoding/raw``
  /// by default.
  public let encoding: Encoding

  /// Returns `nil` when `literal` is empty or contains NUL, or when
  /// `variable` is not a POSIX shell variable name.
  public init?(literal: String, variable: String, encoding: Encoding = .raw) {
    guard !literal.isEmpty, !literal.unicodeScalars.contains("\0"),
      Self.isValidVariableName(variable)
    else { return nil }
    self.literal = literal
    self.variable = variable
    self.encoding = encoding
  }

  /// The double-quoted shell word written in place of the literal: with the
  /// variable set, the shell expands it to exactly the literal.
  public var shellWord: String {
    let reference = "\"$" + variable + "\""
    switch encoding {
    case .raw:
      return reference
    case .base64:
      return "\"$(printf %s " + reference + " | base64 | tr -d '\\n')\""
    case .percentEncoded:
      return "\"$(printf %s " + reference + " | od -A n -t x1 -v | awk "
        + Self.percentEncodingProgram + ")\""
    }
  }

  /// Reads `od`'s hex bytes and prints each RFC 3986 unreserved byte as its
  /// character (48–57, 65–90, 97–122, `-` 45, `.` 46, `_` 95, `~` 126) and
  /// every other byte as `%XX`.
  static let percentEncodingProgram = """
    '{for(i=1;i<=NF;i++){h=tolower($i);\
    d=index("0123456789abcdef",substr(h,1,1))*16+index("0123456789abcdef",substr(h,2,1))-17;\
    if(d>=48&&d<=57||d>=65&&d<=90||d>=97&&d<=122||d==45||d==46||d==95||d==126)printf "%c",d;\
    else printf "%%%s",toupper(h)}}'
    """

  /// `true` for a POSIX shell variable name: `[A-Za-z_][A-Za-z0-9_]*`.
  public static func isValidVariableName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
    return name.unicodeScalars.allSatisfy { scalar in
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", "_": true
      default: false
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case literal, variable, encoding
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let literal = try container.decode(String.self, forKey: .literal)
    let variable = try container.decode(String.self, forKey: .variable)
    // Payloads encoded before `encoding` existed have no such key.
    let encoding = try container.decodeIfPresent(Encoding.self, forKey: .encoding) ?? .raw
    guard
      let substitution = ShellSubstitution(literal: literal, variable: variable, encoding: encoding)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .variable, in: container,
        debugDescription: "An empty literal, a literal with NUL, or an invalid shell variable name."
      )
    }
    self = substitution
  }

  /// Writes `encoding` only when it isn't ``Encoding/raw``, so a plain
  /// substitution encodes as it did before `encoding` existed.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(literal, forKey: .literal)
    try container.encode(variable, forKey: .variable)
    if encoding != .raw { try container.encode(encoding, forKey: .encoding) }
  }
}
