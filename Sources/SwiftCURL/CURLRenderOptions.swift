/// Controls how a ``CURLCommand`` is turned into a shell string.
public struct CURLRenderOptions: Sendable, Hashable, Codable {
  /// The line layout of the rendered command.
  public enum Layout: Sendable, Hashable, Codable {
    /// Every argument on one line, separated by single spaces.
    ///
    /// Arguments that themselves contain newlines (for example a pretty-printed
    /// JSON body) keep them verbatim inside their single quotes. The command is
    /// still a single, valid shell command.
    case singleLine
    /// One option per line, joined with ` \` line continuations and indented
    /// with `indentation`.
    case multiline(indentation: String)
  }

  public var layout: Layout
  public var flagStyle: CURLOption.FlagStyle

  public init(layout: Layout = .singleLine, flagStyle: CURLOption.FlagStyle = .short) {
    self.layout = layout
    self.flagStyle = flagStyle
  }

  /// `curl 'https://…' -X 'POST' -H 'Accept: */*'`
  public static let singleLine = CURLRenderOptions(layout: .singleLine)

  /// ```
  /// curl 'https://…' \
  ///   -X 'POST' \
  ///   -H 'Accept: */*'
  /// ```
  public static let multiline = CURLRenderOptions(layout: .multiline(indentation: "  "))
}
