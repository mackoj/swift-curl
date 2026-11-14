import LLMCheck
import SwiftSyntax

/// The detectors, separate from the codebase so `DetectorTests` can run them on snippets.
enum Detect {
  // MARK: Shell safety

  /// String literals that spell the `'\''` escape, and `replacingOccurrences(of: "'", …)`, outside
  /// `ShellEscaping.swift`: quoting written by hand instead of through `ShellEscaping.quote`.
  static func handWrittenQuoting(in scope: Scope) -> [Match<Syntax>] {
    let outside = scope.excluding("ShellEscaping.swift")
    let escapes = outside.containing("'").nodes(of: StringLiteralExprSyntax.self) {
      let text = text(of: $0.node)
      return text.contains(#"'\''"#) || text.contains(#"'\\''"#)
    }
    let replacements = outside.calls(named: "replacingOccurrences").filter { call in
      guard let of = call.node.argument(labeled: "of")?.expression.as(StringLiteralExprSyntax.self)
      else {
        return false
      }
      return text(of: of).contains("'")
    }
    return escapes.map(\.erased) + replacements.map(\.erased)
  }

  /// String literals holding `$` or a backtick outside `ShellSubstitution.swift`. The one-character literals `"$"`
  /// and `` "`" `` (an HTTP token character, say) pass: they cannot form an expansion on their own.
  static func shellExpansionsOutsideSubstitution(in scope: Scope) -> [Match<
    StringLiteralExprSyntax
  >] {
    scope.excluding("ShellSubstitution.swift").nodes(of: StringLiteralExprSyntax.self) { match in
      let text = text(of: match.node)
      return (text.contains("$") || text.contains("`")) && text != "$" && text != "`"
    }
  }

  /// `quoteIfNeeded` or `isSafeUnquoted` outside `ShellEscaping.swift` on anything but `executable`.
  static func unquotedValues(in scope: Scope) -> [Match<FunctionCallExprSyntax>] {
    scope.excluding("ShellEscaping.swift").calls(named: "quoteIfNeeded", "isSafeUnquoted").filter {
      call in
      call.node.arguments.first?.expression.trimmedDescription != "executable"
    }
  }

  /// The literal's value; for an interpolated literal, its text segments as written.
  static func text(of literal: StringLiteralExprSyntax) -> String {
    if let value = literal.representedLiteralValue { return value }
    return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
  }

  // MARK: Purity

  /// Types whose every use is I/O, a process or shared global state.
  static let impureTypes: Set<String> = [
    "FileManager", "FileHandle", "Process", "ProcessInfo", "Pipe", "URLSession",
    "NotificationCenter",
    "UserDefaults", "Bundle",
  ]

  /// Uses of I/O, a process, a clock, randomness or logging: `FileManager.default`, `Process()`, `Date()`, `UUID()`,
  /// `print(x)`, `NSLog(x)`. `Date(timeIntervalSince1970:)` is pure and passes.
  static func impureCode(in scope: Scope) -> [Match<Syntax>] {
    let logging: Set<String> = ["print", "debugPrint", "NSLog"]
    let calls = scope.calls(named: logging.union(["Date", "UUID"])).filter { call in
      guard call.node.calledExpression.is(DeclReferenceExprSyntax.self),
        let name = call.node.calledName
      else {
        return false
      }
      return logging.contains(name) || call.node.arguments.isEmpty
    }
    return scope.references(to: impureTypes) + calls.map(\.erased)
  }

  // MARK: Platforms

  /// The first `URLRequest` reference in each file that has no `import FoundationNetworking` directly inside
  /// `#if canImport(FoundationNetworking)`. On Linux `URLRequest` lives in FoundationNetworking.
  static func urlRequestWithoutFoundationNetworking(in scope: Scope) -> [Match<Syntax>] {
    let guarded = Set(
      scope.imports(of: "FoundationNetworking").filter { match in
        guard let clause = match.node.enclosingIfConfigClauses.first else { return false }
        return !clause.isElse && clause.ifCondition == "canImport(FoundationNetworking)"
      }.map(\.file.relativePath))
    var reported: Set<String> = []
    return scope.references(to: "URLRequest").filter { match in
      !guarded.contains(match.file.relativePath)
        && reported.insert(match.file.relativePath).inserted
    }
  }

  // MARK: API

  /// Public structs, enums and classes not declared `Sendable`. A caseless enum is a namespace and passes.
  static func publicTypesNotSendable(in scope: Scope) -> [Declaration] {
    (scope.structs + scope.enums + scope.classes).withModifier("public").filter { declaration in
      if declaration.kind == .enum && declaration.cases.isEmpty { return false }
      return !declaration.inherits(from: "Sendable")
    }
  }

  /// Public functions and initializers that throw `any Error`. Codable's `init(from:)` and `encode(to:)` pass:
  /// the protocol fixes their signature.
  static func untypedPublicThrows(in scope: Scope) -> [Declaration] {
    (scope.functions + scope.declarations(.initializer)).withModifier("public").filter {
      declaration in
      let signature: FunctionSignatureSyntax
      if let function = declaration.syntax.as(FunctionDeclSyntax.self) {
        if function.name.text == "encode" && firstLabel(function.signature) == "to" { return false }
        signature = function.signature
      } else if let initializer = declaration.syntax.as(InitializerDeclSyntax.self) {
        if firstLabel(initializer.signature) == "from" { return false }
        signature = initializer.signature
      } else {
        return false
      }
      guard let clause = signature.effectSpecifiers?.throwsClause else { return false }
      return clause.type == nil
    }
  }

  private static func firstLabel(_ signature: FunctionSignatureSyntax) -> String? {
    signature.parameterClause.parameters.first?.firstName.text
  }

  // MARK: Testing

  /// `import XCTest`.
  static func xcTestImports(in scope: Scope) -> [Match<ImportDeclSyntax>] {
    scope.imports(of: "XCTest")
  }

  /// The `.disabled(…)` trait, wherever a test or suite takes it.
  static func disabledTests(in scope: Scope) -> [Match<FunctionCallExprSyntax>] {
    scope.calls(named: "disabled").filter { call in
      call.node.receiver == nil && call.node.calledExpression.is(MemberAccessExprSyntax.self)
    }
  }
}
