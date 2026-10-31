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
public struct ShellSubstitution: Sendable, Hashable, Codable {
  /// The text to replace. Never empty, and never contains NUL (no shell
  /// variable can hold it).
  public let literal: String
  /// The shell variable written in its place. A POSIX name: `[A-Za-z_][A-Za-z0-9_]*`.
  public let variable: String

  /// Returns `nil` when `literal` is empty or contains NUL, or when
  /// `variable` is not a POSIX shell variable name.
  public init?(literal: String, variable: String) {
    guard !literal.isEmpty, !literal.unicodeScalars.contains("\0"),
      Self.isValidVariableName(variable)
    else { return nil }
    self.literal = literal
    self.variable = variable
  }

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
    case literal, variable
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let literal = try container.decode(String.self, forKey: .literal)
    let variable = try container.decode(String.self, forKey: .variable)
    guard let substitution = ShellSubstitution(literal: literal, variable: variable) else {
      throw DecodingError.dataCorruptedError(
        forKey: .variable, in: container,
        debugDescription: "An empty literal, a literal with NUL, or an invalid shell variable name."
      )
    }
    self = substitution
  }
}
