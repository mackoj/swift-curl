import Testing

@testable import SwiftCURL

@Suite("Shell escaping")
struct ShellEscapingTests {
  @Test(arguments: [
    ("", "''"),
    ("plain", "'plain'"),
    ("it's", #"'it'\''s'"#),
    ("''", #"''\'''\'''"#),
    ("'", #"''\'''"#),
    ("$HOME `id` $(id) !! \\ \"x\"", "'$HOME `id` $(id) !! \\ \"x\"'"),
    ("line1\nline2", "'line1\nline2'"),
    ("héllo 😀", "'héllo 😀'"),
  ])
  func quote(input: String, expected: String) {
    #expect(ShellEscaping.quote(input) == expected)
  }

  @Test func quoteNeverContainsUnescapedSingleQuoteOrDoubleQuoteDelimiters() {
    let quoted = ShellEscaping.quote("a'b'c")
    #expect(quoted.hasPrefix("'"))
    #expect(quoted.hasSuffix("'"))
    #expect(quoted == #"'a'\''b'\''c'"#)
  }

  @Test(arguments: ["curl", "-X", "/usr/bin/curl", "a=b", "x@y:1,2+3%"])
  func safeUnquoted(value: String) {
    #expect(ShellEscaping.isSafeUnquoted(value))
    #expect(ShellEscaping.quoteIfNeeded(value) == value)
  }

  @Test(arguments: ["", "a b", "a'b", "$x", "a;b", "a|b", "a&b", "~", "*", "a\nb", "é", "!", "#"])
  func unsafeRequiresQuotes(value: String) {
    #expect(!ShellEscaping.isSafeUnquoted(value))
    #expect(ShellEscaping.quoteIfNeeded(value) == ShellEscaping.quote(value))
  }

  @Test(arguments: ["-X", "-H", "--data-raw", "--http1.1", "--max-time"])
  func plainFlags(flag: String) {
    #expect(ShellEscaping.isPlainFlag(flag))
  }

  @Test(arguments: ["", "-", "--", "X", "--$(id)", "-X;", "--a b", "---x", "-é"])
  func nonPlainFlags(flag: String) {
    #expect(!ShellEscaping.isPlainFlag(flag))
  }
}
