import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension URLRequest {
  /// Converts the request into a typed ``CURLCommand``.
  ///
  /// ```swift
  /// let command = try request.curlCommand()
  /// print(command.render(.multiline))
  /// ```
  public func curlCommand(
    options: CURLConversionOptions = .default
  ) throws(CURLConversionError) -> CURLCommand {
    try CURLConverter(options: options).command(for: self)
  }

  /// Converts the request into a ready-to-run `curl` shell command.
  ///
  /// ```swift
  /// let shell = try request.curl(format: .multiline)
  /// ```
  public func curl(
    options: CURLConversionOptions = .default,
    format: CURLRenderOptions = .singleLine
  ) throws(CURLConversionError) -> String {
    try curlCommand(options: options).render(format)
  }

  /// A best-effort, never-throwing `curl` rendering intended for logging.
  ///
  /// Uses ``CURLConversionOptions/logging`` (credentials redacted, binary and
  /// streamed bodies omitted). If conversion still fails, a shell comment
  /// describing the error is returned so the output remains inert if pasted.
  public var curlDescription: String {
    do {
      return try curl(options: .logging)
    } catch {
      return "# curl conversion failed: \(error.description)"
    }
  }
}
