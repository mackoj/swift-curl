import Foundation
import Testing

@testable import SwiftCURL

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

func makeRequest(
  _ url: String,
  method: String? = nil,
  headers: [String: String] = [:],
  body: Data? = nil
) -> URLRequest {
  var request = URLRequest(url: URL(string: url)!)
  if let method { request.httpMethod = method }
  for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
  request.httpBody = body
  return request
}

extension Data {
  init(utf8 string: String) { self.init(string.utf8) }
}

/// Executes rendered commands in real shells with `curl` replaced by a
/// function that dumps its argv (NUL-separated) and its standard input.
/// This proves the command is syntactically valid *and* that the shell hands
/// curl exactly the intended arguments, with no expansion or injection.
enum Shell {
  struct Invocation: Equatable {
    var arguments: [String]
    var standardInput: Data
  }

  struct Failure: Error, CustomStringConvertible {
    var description: String
  }

  /// Shells installed on this machine (bash, sh/dash, zsh).
  static let available: [String] = {
    var seen = Set<String>()
    var result: [String] = []
    for path in ["/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/zsh", "/bin/dash", "/bin/ksh"] {
      let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
      guard FileManager.default.isExecutableFile(atPath: path),
        seen.insert(URL(fileURLWithPath: resolved).lastPathComponent).inserted
      else { continue }
      result.append(path)
    }
    return result
  }()

  private static let stub = """
    curl() { printf '%s\\0' "$#"; for a in "$@"; do printf '%s\\0' "$a"; done; cat; }
    """

  /// Runs `command` in `shell` and returns what `curl` received.
  static func invoke(_ command: String, shell: String = "/bin/bash") throws -> Invocation {
    let output = try run(shell, ["-c", stub + "\n" + command])
    guard output.status == 0 else {
      throw Failure(description: "\(shell) exited with \(output.status): \(output.stderr)")
    }
    return try parse(output.stdout)
  }

  /// Returns `true` when `shell -n` accepts the command (syntax check only).
  static func parses(_ command: String, shell: String = "/bin/bash") throws -> Bool {
    try run(shell, ["-n", "-c", command]).status == 0
  }

  private static func run(
    _ shell: String, _ arguments: [String]
  ) throws -> (status: Int32, stdout: Data, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, out, String(decoding: err, as: UTF8.self))
  }

  private static func parse(_ data: Data) throws -> Invocation {
    let bytes = [UInt8](data)
    var cursor = 0
    func field() throws -> String {
      guard let end = bytes[cursor...].firstIndex(of: 0) else {
        throw Failure(description: "Malformed stub output")
      }
      defer { cursor = end + 1 }
      return String(decoding: bytes[cursor..<end], as: UTF8.self)
    }
    guard let count = Int(try field()) else { throw Failure(description: "Missing argc") }
    var arguments: [String] = []
    for _ in 0..<count { arguments.append(try field()) }
    return Invocation(arguments: arguments, standardInput: Data(bytes[cursor...]))
  }
}

/// Deterministic pseudo-random generator (SplitMix64) for reproducible fuzzing.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
