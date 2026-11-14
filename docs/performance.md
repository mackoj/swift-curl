# Measuring and profiling

The benchmarks live in `Benchmarks/`, a separate package on [package-benchmark](https://github.com/ordo-one/package-benchmark)
([Swift.org's introduction](https://www.swift.org/blog/benchmarks/)), so the library keeps no dependencies. It needs
macOS 15 and jemalloc (`brew install jemalloc`). Run everything from the repository root.

## What is measured

Each benchmark reports wall clock, CPU time, mallocs, peak resident memory and retains.

| Benchmark | What it runs |
|---|---|
| Convert and render, simple GET | `request.curl()` on a GET with no headers or body (per operation) |
| Log description, simple GET | `request.curlDescription`, the `.logging` preset (per operation) |
| Convert and render, 50 headers | 100 × `curl(format: .multiline)` on a POST with 50 headers, a cookie and a JSON body |
| Log description, 50 headers | the same request, 100 × `curlDescription` (redaction on) |
| Convert and render, 1 MB JSON body | `curl()` on 1 MB of JSON holding `'`, `$`, backticks and non-ASCII text |
| Render, 1 MB JSON body | `render()` of that command, conversion excluded |
| Convert and render, 1 MB binary body | `curl()` on 1 MB of random bytes, piped through base64 |
| Render, 1 MB binary body | `render()` of that command |
| Quote, 64 KB adversarial | `ShellEscaping.quote` on every shell metacharacter, quotes, newlines and Unicode |
| Quote, short values | `ShellEscaping.quote` on six header-sized values (per operation) |
| Quote with substitutions, 128 KB, one match | `quote(_:substituting:)` with raw, base64 and percent-encoded substitutions |
| Quote with substitutions, 64 KB, no match | the scan alone, nothing to replace |
| Render, encoded substitutions | a request carrying a token raw, in Basic auth and percent-encoded (per operation) |
| Render, 1 MB JSON body, substitution | a substitution over the 1 MB text body |
| Render, 64 KB binary body, substitution | a token inside a piped binary body, every 4 KB |

## Measure a change

Save `main`'s numbers before you change code, then compare the same harness after:

```sh
mkdir -p .build
swift package --package-path Benchmarks benchmark --format markdown --no-progress > .build/before.md
# … change the code …
swift package --package-path Benchmarks benchmark --format markdown --no-progress > .build/after.md
swift run --package-path Benchmarks -c release p50 .build/before.md .build/after.md
```

`p50` prints a Markdown table of each benchmark's median wall clock and mallocs, before → after, ready for the pull
request. Malloc and retain counts are deterministic; wall clock moves a few percent between runs, so rerun a benchmark
before trusting a small change.

- `--filter` takes a regular expression: `--filter 'Render, 1 MB.*'`. Benchmark names avoid `(` and `)` so a name
  can be passed as is.
- Per-operation benchmarks (`scalingFactor: .kilo`) report nanoseconds per operation, marked `*` in
  package-benchmark's tables; `p50` converts them to microseconds.
- `benchmark baseline update` / `baseline compare` are package-benchmark's own thresholds and stay available.

## Profile a benchmark

```sh
Benchmarks/scripts/profile.sh 'Convert and render, 50 headers' 25
```

It runs that one benchmark under Instruments' Time Profiler and prints:

- **Self**: the functions the samples were in. `_platform_memmove` at the top means copying (it was 77% of quoting
  before 0.3.1: a quadratic string append); `objc_msgSend` and `CFString…` mean bridged Foundation strings.
- **Inclusive**: the swift-curl functions with the most samples under them, which says whose work it is.

The trace stays in `Benchmarks/.build/profiles/` to open in Instruments.

## What has paid off

Before → after on an Apple M5 Pro, release build, p50 (2026-11-14). The 50-header rows are 100 conversions.

| Benchmark | Wall clock p50 (µs) | Mallocs p50 |
|---|---|---|
| Convert and render, simple GET | 5.1 → 3.2 (0.63x) | 5 → 5 |
| Log description, simple GET | 4.8 → 2.9 (0.60x) | 5 → 5 |
| Convert and render, 50 headers | 19,169 → 11,420 (0.60x) | 48,100 → 42,900 (0.89x) |
| Log description, 50 headers | 19,104 → 10,961 (0.57x) | 53,000 → 43,400 (0.82x) |
| Convert and render, 1 MB JSON body | 150,995 → 4,657 (0.03x) | 30,111 → 27 |
| Render, 1 MB JSON body | 172,491 → 1,533 (0.01x) | 30,096 → 16 |
| Convert and render, 1 MB binary body | 69,534 → 1,102 (0.02x) | 33 → 26 |
| Render, 1 MB binary body | 37,257 → 657 (0.02x) | 20 → 15 |
| Quote, 64 KB adversarial | 7,713 → 98 (0.01x) | 10,123 → 1 |
| Quote, short values | 1.8 → 0.3 (0.19x) | 5 → 3 |
| Quote with substitutions, 128 KB, one match | 18,694 → 372 (0.02x) | 20,282 → 14 |
| Quote with substitutions, 64 KB, no match | 8,987 → 193 (0.02x) | 10,138 → 4 |
| Render, encoded substitutions | 19.1 → 3.7 (0.20x) | 78 → 35 (0.45x) |
| Render, 1 MB JSON body, substitution | 173,801 → 2,408 (0.01x) | 30,124 → 19 |
| Render, 64 KB binary body, substitution | 3,250 → 193 (0.06x) | 322 → 153 (0.48x) |

Peak resident memory rendering the 1 MB JSON body went from 32 MB to 25 MB.

- **Quote over UTF-8 bytes into one allocation.** `ShellEscaping.quote` appended scalar by scalar through
  `result.unicodeScalars`, which copied the whole string on each append: quadratic, 170 ms for 1 MB. It now counts the
  `'` bytes, sizes the result once and copies. `'` is ASCII, so replacing its byte never touches a multi-byte scalar:
  the output is the same, scalar for scalar.
- **Match substitutions on bytes, prepared once per render.** A literal starts and ends on a scalar boundary, so a
  UTF-8 byte match is a scalar match. `render` builds the patterns and their shell words once, not once per value, and
  a first-byte table skips most positions. A piped binary body is decoded from base64 only when there are
  substitutions to look for.
- **Reject binary bodies before decoding them.** Control bytes are found in one pass over the raw bytes, so random
  data fails within a few bytes instead of after a full, repairing UTF-8 decode through `Data`'s generic iterator.
- **Read each header once.** Names are lowercased once per header, not in every sort comparison and every
  `excludedHeaders`/`redactedHeaders` lookup, and bridged `NSString` headers are copied to native UTF-8 once.
- What remains for headers is Foundation's: `URLRequest.allHTTPHeaderFields` alone is about 45% of the 50-header
  conversion (bridging the `NSDictionary`).
