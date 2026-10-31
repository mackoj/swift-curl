/// A single `curl` command-line option.
///
/// Each case maps to exactly one curl flag and, when the flag takes one, its
/// value. Values are always rendered inside single quotes; flags are rendered
/// bare when they are plain (`-H`, `--data-raw`) and quoted otherwise.
public enum CURLOption: Sendable, Hashable, Codable {
  /// `-X, --request <method>`
  case request(String)
  /// `-H, --header <header>`. An empty value renders as `Name;`, which is how
  /// curl sends a header with an empty value (`Name:` would *remove* it).
  case header(name: String, value: String)
  /// `-d, --data <data>`. Note that a leading `@` makes curl read a file.
  case data(String)
  /// `--data-raw <data>`: like `--data` but `@` is not special.
  case dataRaw(String)
  /// `--data-binary <data>`: `@path` reads a file, `@-` reads standard input.
  case dataBinary(String)
  /// `--data-urlencode <data>`
  case dataURLEncode(String)
  /// `-F, --form <name=content>`: `@` and `<` prefixes are interpreted by curl.
  case form(String)
  /// `--form-string <name=string>`: the value is sent literally.
  case formString(String)
  /// `-b, --cookie <data|filename>`
  case cookie(String)
  /// `-c, --cookie-jar <filename>`
  case cookieJar(String)
  /// `-u, --user <user:password>`
  case user(String)
  /// `-A, --user-agent <name>`
  case userAgent(String)
  /// `-e, --referer <URL>`
  case referer(String)
  /// `-x, --proxy <[protocol://]host[:port]>`
  case proxy(String)
  /// `-o, --output <file>`
  case output(String)
  /// `-m, --max-time <seconds>`
  case maxTime(Double)
  /// `--connect-timeout <seconds>`
  case connectTimeout(Double)
  /// `-L, --location`
  case location
  /// `--compressed`
  case compressed
  /// `-I, --head`
  case head
  /// `-G, --get`
  case get
  /// `-k, --insecure`
  case insecure
  /// `-v, --verbose`
  case verbose
  /// `-s, --silent`
  case silent
  /// `-S, --show-error`
  case showError
  /// `-i, --include`
  case include
  /// `-f, --fail`
  case fail
  /// `-g, --globoff`: disables curl's `[]`/`{}` URL globbing.
  case globOff
  /// `--http1.1`
  case http1_1
  /// `--http2`
  case http2
  /// Any other flag. `flag` is rendered bare only if it is a plain flag
  /// (e.g. `--retry`); otherwise it is quoted like a value.
  case custom(flag: String, value: String?)

  /// How flags are spelled when rendered.
  public enum FlagStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// Prefer short flags (`-H`, `-X`, `-b`) when curl has one.
    case short
    /// Always use long flags (`--header`, `--request`, `--cookie`).
    case long
  }

  /// The flag and optional value for this option.
  public func components(flagStyle: FlagStyle = .short) -> (flag: String, value: String?) {
    func pick(_ short: String, _ long: String) -> String {
      flagStyle == .short ? short : long
    }
    switch self {
    case .request(let method): return (pick("-X", "--request"), method)
    case .header(let name, let value):
      return (pick("-H", "--header"), value.isEmpty ? "\(name);" : "\(name): \(value)")
    case .data(let value): return (pick("-d", "--data"), value)
    case .dataRaw(let value): return ("--data-raw", value)
    case .dataBinary(let value): return ("--data-binary", value)
    case .dataURLEncode(let value): return ("--data-urlencode", value)
    case .form(let value): return (pick("-F", "--form"), value)
    case .formString(let value): return ("--form-string", value)
    case .cookie(let value): return (pick("-b", "--cookie"), value)
    case .cookieJar(let value): return (pick("-c", "--cookie-jar"), value)
    case .user(let value): return (pick("-u", "--user"), value)
    case .userAgent(let value): return (pick("-A", "--user-agent"), value)
    case .referer(let value): return (pick("-e", "--referer"), value)
    case .proxy(let value): return (pick("-x", "--proxy"), value)
    case .output(let value): return (pick("-o", "--output"), value)
    case .maxTime(let seconds): return (pick("-m", "--max-time"), Self.format(seconds))
    case .connectTimeout(let seconds): return ("--connect-timeout", Self.format(seconds))
    case .location: return (pick("-L", "--location"), nil)
    case .compressed: return ("--compressed", nil)
    case .head: return (pick("-I", "--head"), nil)
    case .get: return (pick("-G", "--get"), nil)
    case .insecure: return (pick("-k", "--insecure"), nil)
    case .verbose: return (pick("-v", "--verbose"), nil)
    case .silent: return (pick("-s", "--silent"), nil)
    case .showError: return (pick("-S", "--show-error"), nil)
    case .include: return (pick("-i", "--include"), nil)
    case .fail: return (pick("-f", "--fail"), nil)
    case .globOff: return (pick("-g", "--globoff"), nil)
    case .http1_1: return ("--http1.1", nil)
    case .http2: return ("--http2", nil)
    case .custom(let flag, let value): return (flag, value)
    }
  }

  /// The raw (unquoted) argument vector for this option, as curl will see it.
  public func arguments(flagStyle: FlagStyle = .short) -> [String] {
    let (flag, value) = components(flagStyle: flagStyle)
    return value.map { [flag, $0] } ?? [flag]
  }

  /// `true` for options that make curl send a request body.
  public var sendsBody: Bool {
    switch self {
    case .data, .dataRaw, .dataBinary, .dataURLEncode, .form, .formString: true
    default: false
    }
  }

  /// Formats seconds without locale influence and without a trailing `.0`.
  static func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0" }
    if seconds == seconds.rounded(), abs(seconds) < 1e15 {
      return String(Int64(seconds))
    }
    return String(seconds)
  }
}
