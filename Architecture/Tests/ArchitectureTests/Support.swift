import LLMCheck

/// The swift-curl repository, rooted where `.llm-check.yaml` is. Its file list and every parsed file are shared by
/// all suites, which Swift Testing runs in parallel.
func swiftCURL() throws -> Codebase { try Codebase() }

extension RuleCategory {
  static let shellSafety = RuleCategory(
    "shell-safety",
    description:
      "Quoting and expansions. Read before you change how anything is rendered as shell text."
  )
  static let purity = RuleCategory(
    "purity",
    description:
      "The library is pure. Read before you reach for the file system, a process, a clock or a log."
  )
  static let platforms = RuleCategory(
    "platforms",
    description: "Linux support. Read before you add an `import` or use a networking type."
  )
  static let api = RuleCategory(
    "api",
    description: "Public types and errors. Read before you add or change a public declaration."
  )
  static let testing = RuleCategory(
    "testing",
    description: "Swift Testing, and no silenced tests. Read before you add, skip or change a test."
  )
}
