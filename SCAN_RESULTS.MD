
## Baseline Vulnerability Scan (Grype)

Scanned with Grype, DB updated <date from `grype db status`>.

### Summary

| Metric | single-v1 (`golang:1.18`) | multi-v1 (distroless/static) | Reduction |
|---|---:|---:|---:|
| Image size (on disk) | 1.65 GB | 16.1 MB | ~99% |
| Image size (compressed) | 409 MB | 3.59 MB | ~99% |
| **Unique CVEs** | **817** | **72** | **91%** |
| Critical | 50 | 5 | 90% |
| High | 268 | 38 | 86% |
| Medium | 265 | 27 | 90% |
| Low | 39 | 1 | 97% |
| Negligible | 194 | 0 | 100% |
| Unknown | 1 | 1 | – |
| CVEs with a fix available | 457 (56%) | 72 (100%) | – |

### Matches by package type

Counts are total matches, so one CVE can match several packages.

| Package type | single-v1 | multi-v1 |
|---|---:|---:|
| `deb` (Debian OS packages) | 1,824 | 0 |
| `go-module` (app deps + Go stdlib) | 400 | 76 |
| `binary` (Go 1.18 toolchain binaries) | 117 | 0 |
| Of which: Go stdlib | 383 | 59 |

## Remediation Results (Grype)

Scanned with Grype, DB updated <date>.

| Metric | single-v1 | single-v2 | multi-v1 | multi-v2 |
|---|---:|---:|---:|---:|
| Build base | `golang:1.18` | `golang:1.xx` | `golang:1.18` | `cgr.dev/chainguard/go` |
| Runtime base | `golang:1.18` | `golang:1.xx` | `distroless/static` | `cgr.dev/chainguard/static` |
| App deps | Go 1.18, gin 1.8.1 | Patched | Go 1.18, gin 1.8.1 | Patched |
| Image size (disk) | 1.65 GB | <fill> | 16.1 MB | <fill> |
| Packages detected | – | 239 | – | 23 |
| **Unique CVEs** | **817** | **266** | **72** | **0** |
| Critical | 50 | 8 | 5 | 0 |
| High | 268 | 40 | 38 | 0 |
| Medium | 265 | 50 | 27 | 0 |
| Low | 39 | 14 | 1 | 0 |
| Negligible | 194 | 138 | 0 | 0 |
| Unknown | 1 | 16 | 1 | 0 |
| Fix available | 457 | 1 | 72 | 0 |
| Go stdlib/module matches | 400 | 0 | 76 | 0 |
| Debian OS matches | 1,824 | 1,118 | 0 | 0 |

**Reduction from single-v1 to multi-v2: 817 → 0 CVEs (100%).**
