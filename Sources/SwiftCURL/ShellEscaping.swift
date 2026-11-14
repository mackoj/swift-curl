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
    if let quoted = value.utf8.withContiguousStorageIfAvailable(quote) { return quoted }
    return Array(value.utf8).withUnsafeBufferPointer(quote)
  }

  /// Quotes valid UTF-8. `'` is ASCII, so it is never part of a multi-byte
  /// sequence: replacing that byte keeps the text valid and changes nothing
  /// else, scalar for scalar.
  static func quote(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
    let quote = UInt8(ascii: "'")
    var quotes = 0
    for byte in bytes where byte == quote { quotes += 1 }
    // Each `'` becomes the four bytes `'\''`.
    return String(unsafeUninitializedCapacity: bytes.count + 2 + 3 * quotes) { buffer in
      buffer[0] = quote
      var count = 1
      if quotes == 0 {
        if let base = bytes.baseAddress {
          (buffer.baseAddress! + 1).initialize(from: base, count: bytes.count)
        }
        count += bytes.count
      } else {
        for byte in bytes {
          if byte == quote {
            buffer[count] = quote
            buffer[count + 1] = UInt8(ascii: "\\")
            buffer[count + 2] = quote
            buffer[count + 3] = quote
            count += 4
          } else {
            buffer[count] = byte
            count += 1
          }
        }
      }
      buffer[count] = quote
      return count + 1
    }
  }

  /// Quotes `value` as one shell word, writing each occurrence of a
  /// substitution's literal as its variable, `"$NAME"` (or, for an encoded
  /// substitution, the expression that encodes it, ``ShellSubstitution/shellWord``),
  /// and every other run of text single-quoted as in ``quote(_:)``.
  ///
  /// ```swift
  /// let key = ShellSubstitution(literal: "s3cr3t", variable: "KEY")!
  /// ShellEscaping.quote("k=s3cr3t&q=it's", substituting: [key])
  /// // 'k='"$KEY"'&q=it'\''s'
  /// ```
  ///
  /// Matching is on Unicode scalars, left to right; where several literals
  /// match at the same place, the longest wins, then the first given. With each
  /// variable set to its literal (for an encoded substitution, to the value
  /// whose encoding is the literal), the shell yields exactly `value`.
  public static func quote(
    _ value: String, substituting substitutions: [ShellSubstitution]
  ) -> String {
    guard !substitutions.isEmpty else { return quote(value) }
    return Substituter(substitutions).quote(value)
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

/// The substitutions of one rendering, prepared once: each literal's UTF-8
/// bytes and shell word, and which bytes can start a literal.
///
/// Matching on UTF-8 bytes is matching on Unicode scalars: a literal starts
/// with a scalar's first byte, which in valid UTF-8 only ever starts a scalar,
/// and ends with a scalar's last byte, so a byte match spans whole scalars.
struct Substituter {
  private let patterns: [(bytes: [UInt8], word: String)]
  private let startsPattern: [Bool]

  init(_ substitutions: [ShellSubstitution]) {
    patterns = substitutions.map { (Array($0.literal.utf8), $0.shellWord) }
    guard !patterns.isEmpty else {
      startsPattern = []
      return
    }
    var startsPattern = [Bool](repeating: false, count: 256)
    for pattern in patterns {
      if let first = pattern.bytes.first { startsPattern[Int(first)] = true }
    }
    self.startsPattern = startsPattern
  }

  var isEmpty: Bool { patterns.isEmpty }

  /// The longest literal at `index`, then the first given.
  func match(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> (length: Int, word: String)? {
    guard startsPattern[Int(bytes[index])] else { return nil }
    var match: (length: Int, word: String)?
    for pattern in patterns
    where pattern.bytes.count > (match?.length ?? 0)
      && bytes.count - index >= pattern.bytes.count
      && UnsafeBufferPointer(rebasing: bytes[index..<(index + pattern.bytes.count)])
        .elementsEqual(pattern.bytes)
    {
      match = (pattern.bytes.count, pattern.word)
    }
    return match
  }

  /// ``ShellEscaping/quote(_:substituting:)``.
  func quote(_ value: String) -> String {
    if let quoted = value.utf8.withContiguousStorageIfAvailable(quote) { return quoted }
    return Array(value.utf8).withUnsafeBufferPointer(quote)
  }

  private func quote(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
    var result = ""
    var literalStart = 0
    var index = 0
    while index < bytes.count {
      if let match = match(in: bytes, at: index) {
        if literalStart < index {
          result += ShellEscaping.quote(UnsafeBufferPointer(rebasing: bytes[literalStart..<index]))
        }
        result += match.word
        index += match.length
        literalStart = index
      } else {
        index += 1
      }
    }
    if literalStart < bytes.count || result.isEmpty {
      result += ShellEscaping.quote(UnsafeBufferPointer(rebasing: bytes[literalStart...]))
    }
    return result
  }
}
