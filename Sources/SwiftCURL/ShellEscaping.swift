/// POSIX shell quoting helpers.
///
/// Every value produced by this package is wrapped in **single quotes**.
/// Inside single quotes a POSIX shell (sh, bash, zsh, dash, ksh) performs no
/// expansion at all: `$`, `` ` ``, `!`, `\`, `*`, `?`, `[`, `~`, `"` and
/// newlines are taken literally. The only character that cannot appear inside
/// single quotes is the single quote itself, which is emitted as `'\''`
/// (close quote, escaped literal quote, reopen quote).
public enum ShellEscaping {
  /// Wraps `value` in single quotes, escaping embedded single quotes as `'\''`.
  ///
  /// ```swift
  /// ShellEscaping.quote("it's $HOME")  // 'it'\''s $HOME'
  /// ShellEscaping.quote("")            // ''
  /// ```
  ///
  /// - Note: A NUL character (`U+0000`) cannot be passed as part of a process
  ///   argument by any shell. ``CURLConverter`` never produces arguments
  ///   containing NUL; binary payloads are routed through standard input
  ///   instead (see ``CURLConversionOptions/BinaryBodyStrategy``).
  public static func quote(_ value: String) -> String {
    var result = "'"
    result.reserveCapacity(value.utf8.count + 2)
    for character in value.unicodeScalars {
      if character == "'" {
        result.unicodeScalars.append(contentsOf: #"'\''"#.unicodeScalars)
      } else {
        result.unicodeScalars.append(character)
      }
    }
    result.unicodeScalars.append("'")
    return result
  }

  /// Returns `true` when `value` is non-empty and made only of characters that
  /// no POSIX shell treats specially, so it can safely be emitted without quotes.
  ///
  /// The allowed set is `[A-Za-z0-9]` plus `_ - . / : , + = @ %`.
  public static func isSafeUnquoted(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.unicodeScalars.allSatisfy(isSafeScalar)
  }

  /// Quotes `value` only when it contains characters that are not
  /// ``isSafeUnquoted(_:)``.
  public static func quoteIfNeeded(_ value: String) -> String {
    isSafeUnquoted(value) ? value : quote(value)
  }

  /// Returns `true` when `flag` looks like a command-line flag
  /// (`-X`, `--data-raw`, `--http1.1`) and may be emitted unquoted.
  static func isPlainFlag(_ flag: String) -> Bool {
    let scalars = Array(flag.unicodeScalars)
    guard scalars.count >= 2, scalars[0] == "-" else { return false }
    let body = scalars[1] == "-" ? scalars.dropFirst(2) : scalars.dropFirst(1)
    guard let first = body.first, isAlphanumeric(first) else { return false }
    return body.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "." }
  }

  private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9": true
    default: false
    }
  }

  private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
    if isAlphanumeric(scalar) { return true }
    switch scalar {
    case "_", "-", ".", "/", ":", ",", "+", "=", "@", "%": return true
    default: return false
    }
  }
}
