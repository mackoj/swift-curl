# swift-curl

Convert Foundation's `URLRequest` into **safe, executable `curl` commands**.

`swift-curl` turns a request into a typed `CURLCommand` that you can inspect or change, then renders it as a shell command. It does not wrap `libcurl` and it is not an HTTP client.

- **Swift 6** language mode, `Sendable` throughout, typed throws, no warnings.
- **Foundation only**, no third-party dependencies. Runs on Apple platforms and Linux.
- **Injection-safe**: every value is wrapped in single quotes, and embedded quotes are escaped as POSIX `'\''`. Double quotes are never used for quoting.
- **Verified in real shells**: the test suite runs the generated commands in bash, sh/dash, zsh and ksh, and checks the exact argv curl receives.

## Installation

```swift
.package(url: "https://github.com/mackoj/swift-curl.git", from: "0.1.0"),
```

```swift
.target(name: "MyTarget", dependencies: [.product(name: "SwiftCURL", package: "swift-curl")]),
```

## Usage

```swift
import SwiftCURL

var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = Data(#"{"name":"O'Brien"}"#.utf8)

print(try request.curl())
// curl 'https://api.example.com/users' -H 'Content-Type: application/json' --data-raw '{"name":"O'\''Brien"}'

print(try request.curl(format: .multiline))
// curl 'https://api.example.com/users' \
//   -H 'Content-Type: application/json' \
//   --data-raw '{"name":"O'\''Brien"}'

// For logs: never throws; redacts credentials and omits binary or streamed bodies.
logger.debug("\(request.curlDescription)")
```

### Working with the model

```swift
var command = try request.curlCommand(options: .init {
  $0.followRedirects = true
  $0.redactedHeaders = ["Authorization"]
})
command.options.append(.verbose)

command.arguments()     // the exact argv curl receives, before shell quoting
command.render(.init(layout: .multiline(indentation: "    "), flagStyle: .long))
```

`CURLCommand` and `CURLOption` are `Sendable`, `Hashable` and `Codable`.

## Behaviour

| Request | Output |
|---|---|
| `GET` with no body | no `-X` |
| `POST` with a body | no `-X`, because curl infers POST from the data flag |
| any other method, or `GET` with a body | `-X 'METHOD'` |
| `HEAD` | `-I` (`-X HEAD` makes curl wait for a body that never arrives) |
| custom verbs (`PROPFIND`, …) | `-X 'PROPFIND'`; invalid tokens (spaces, CR/LF) are rejected |
| headers | `-H 'Name: Value'`, sorted. An empty value becomes `-H 'Name;'` |
| `Cookie` header | `-b 'a=1; b=2'`, or `-H` when the value has no `=` (`-b` would treat it as a file name) |
| text / JSON body | `--data-raw '…'`. A body starting with `@` always uses `--data-raw`, so curl never reads a file |
| empty body (`Data()`) | `--data-raw ''`; a `nil` body produces nothing |
| binary body | `printf '%s' '<base64>' \| base64 --decode \| curl … --data-binary @-` |
| `httpBodyStream` | throws by default; `.omit` or `.read(maxLength:)` are available |
| multipart | sent raw and byte-exact by default; `.formFields` rewrites parts as `--form-string` / `-F` |
| URL containing `[ ] { }` | adds `-g`, which turns off curl URL globbing |
| URL starting with `-` | `--url '…'` |

A body counts as **binary** if it is not valid UTF-8, or if it contains control characters other than tab, CR and LF. That includes NUL, which no shell argument can carry, and terminal escape sequences.

### Conversion options

| Option | Default | Notes |
|---|---|---|
| `alwaysIncludeMethod` | `false` | Always emit `-X` |
| `textBodyFlag` | `.dataRaw` | `.data`, `.dataBinary` |
| `binaryBodyStrategy` | `.base64Pipeline` | `.file(path:)`, `.omit`, `.throwError` |
| `bodyStreamStrategy` | `.throwError` | `.omit`, `.read(maxLength:)` (this consumes the stream) |
| `multipartStrategy` | `.raw` | `.formFields(fileDirectory:)` |
| `cookieStrategy` | `.cookieFlag` | `.header` |
| `additionalCookies` | `[]` | Merged into `-b` |
| `excludedHeaders` / `redactedHeaders` | `[]` | Case-insensitive |
| `followRedirects`, `compressed`, `includeTimeout` | `false` | `-L`, `--compressed`, `-m <timeoutInterval>` |
| `additionalOptions` | `[]` | Any `CURLOption`, including `.custom(flag:value:)` |

Presets: `.default` (faithful) and `.logging` (redacts `Authorization`, `Proxy-Authorization`, `Cookie`, `X-API-Key` and `X-Auth-Token`; omits binary and streamed bodies).

### Errors

`CURLConversionError` covers a missing URL, an invalid method, an invalid header name, a header value containing CR, LF or NUL (header injection), a binary body when binary is not allowed, and body stream failures.

### Single-line output and newlines

`.singleLine` puts each argument on one line. Arguments that contain newlines, such as pretty-printed JSON, keep those newlines inside their single quotes. The command is still one valid shell command.

## Testing

```bash
swift test
```

The suite uses Swift Testing. `ShellRoundTripTests` replaces `curl` with a shell function that dumps its argv and stdin. It runs each command in every POSIX shell installed on the machine. It checks that the arguments match `CURLCommand.arguments()` exactly, and that hostile and fuzzed input (`$()`, backticks, `!!`, quotes, newlines, Unicode) is never expanded.
