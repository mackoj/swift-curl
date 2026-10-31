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
  /// Literals written as shell variables (`"$NAME"`) wherever they appear in
  /// the URL, an option value or the standard-input payload. Flags and the
  /// executable are never substituted. Empty by default.
  public var substitutions: [ShellSubstitution]

  public init(
    layout: Layout = .singleLine,
    flagStyle: CURLOption.FlagStyle = .short,
    substitutions: [ShellSubstitution] = []
  ) {
    self.layout = layout
    self.flagStyle = flagStyle
    self.substitutions = substitutions
  }

  private enum CodingKeys: String, CodingKey {
    case layout, flagStyle, substitutions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    layout = try container.decode(Layout.self, forKey: .layout)
    flagStyle = try container.decode(CURLOption.FlagStyle.self, forKey: .flagStyle)
    // Payloads encoded before `substitutions` existed have no such key.
    substitutions =
      try container.decodeIfPresent([ShellSubstitution].self, forKey: .substitutions) ?? []
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
