# Findings: Vulnerability Scans & SBOM Analysis

- **Scanner:** Grype <!-- TODO: version -->, vulnerability DB built <!-- TODO: date from `grype db status` -->
- **Method:** `grype docker:localhost:5001/hello:<tag> -o json`, summarized with [`../summarize.sh`](../summarize.sh)
- **Counts:** unique CVE IDs by severity. Package-type rows count *matches*, since one CVE can match several packages.

> Results are a snapshot as of the DB date above. New CVEs are published daily, so these numbers change over time.

## Images compared

| Image | Build base | Runtime base | App dependencies |
|---|---|---|---|
| `single-v1` | `golang:1.18` | `golang:1.18` | Go 1.18, Gin 1.8.1 (original) |
| `multi-v1` | `golang:1.18` | `gcr.io/distroless/static-debian12:nonroot` | Go 1.18, Gin 1.8.1 (original) |
| `single-v2` | `golang:<current>` | `golang:<current>` | Patched (current Go, `go get -u`) |
| `multi-v2` | `cgr.dev/chainguard/go:latest` | `cgr.dev/chainguard/static:latest` | Patched (current Go, `go get -u`) |

## 1. Before remediation: single-stage vs multi-stage

| Metric | single-v1 | multi-v1 | Reduction |
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

| Matches by package type | single-v1 | multi-v1 |
|---|---:|---:|
| `deb` (Debian OS packages) | 1,824 | 0 |
| `go-module` (app deps + Go stdlib) | 400 | 76 |
| `binary` (Go 1.18 toolchain binaries) | 117 | 0 |
| of which: Go stdlib | 383 | 59 |

**Takeaways**
- The multi-stage build removed **91% of CVEs and 99% of the size** with no code change. All Debian and toolchain matches were gone.
- The **72 CVEs left in `multi-v1` are inside the binary**: 59 Go 1.18 stdlib matches, plus modules such as `golang.org/x/net`, `x/crypto` and `gin`. A smaller base can't remove these.
- **All 72 had a fix available.** The problem is a missing rebuild, not a missing patch.
- `single-v1` ships a **compiler** (`binary` matches = the Go toolchain) and runs as root.

## 2. After remediation

| Metric | single-v1 | single-v2 | multi-v1 | multi-v2 |
|---|---:|---:|---:|---:|
| Image size (disk) | 1.65 GB | <!-- TODO --> | 16.1 MB | <!-- TODO --> |
| **Unique CVEs** | **817** | **266** | **72** | **0** |
| Critical | 50 | 8 | 5 | 0 |
| High | 268 | 40 | 38 | 0 |
| Medium | 265 | 50 | 27 | 0 |
| Low | 39 | 14 | 1 | 0 |
| Negligible | 194 | 138 | 0 | 0 |
| Unknown | 1 | 16 | 1 | 0 |
| Fix available | 457 | **1** | 72 | 0 |
| Go stdlib/module matches | 400 | 0 | 76 | 0 |
| Debian OS matches | 1,824 | 1,118 | 0 | 0 |

**Overall: 817 → 0 unique CVEs (−100%).**

**Takeaways**
1. **Patching the app removed every Go CVE** in both v2 images (Go matches 400/76 → 0).
2. **You can't patch your way out of a traditional base image.** `single-v2` still has **266 CVEs, all in Debian packages, and only 1 has a fix available**. Rebuilding can't fix the other 265; they can only be accepted, suppressed or argued about.
3. **Both layers had to be fixed:**

   | | Old app | Patched app |
   |---|---|---|
   | **Traditional base** | single-v1: 817 | single-v2: 266 |
   | **Minimal base** | multi-v1: 72 | **multi-v2: 0** |

4. **Zero is a point in time.** It stays at zero only through continuous rebuilds of the base and the app.

## 3. Reachability (govulncheck)

`govulncheck -mode=binary` on the `multi-v1` binary: <!-- TODO: summarize reports/before/govulncheck-multi-v1.txt, e.g. "N vulnerabilities reachable vs 72 reported by Grype" -->

`govulncheck ./...` after patching: No vulnerabilities found.

Takeaway: scanners report what's *present*; govulncheck reports what's *reachable*. Both views are useful. The first measures attack surface and compliance, the second helps prioritize.

## 4. SBOM insights

Generated with Syft in SPDX 2.3 JSON and CycloneDX JSON (`../sboms/`), and attached to each image as a cosign-signed SPDX attestation.

| Image | Packages | CVEs |
|---|---:|---:|
| single-v1 | 261 | 817 |
| single-v2 | 254 | 266 |
| multi-v1 | 23 | 72 |
| multi-v2 | 25 | 0 |

- **Most of a traditional image is OS, not app.** About 90% of the single-stage SBOM is Debian packages the app never uses, and each one has to be tracked, patched and license-checked.
- **Patching barely changed `single-v2`'s contents** (261 → 254 packages), because the heavy base stays.
- **Package count isn't the whole story.** `multi-v1` and `multi-v2` have almost the same count (23 vs 25), but 72 vs 0 CVEs. The difference is freshness. The upgraded Gin pulled in a few new modules, so the count went *up* while the CVEs went to zero.
- **An SBOM lets you rescan without the image:** `grype sbom:sboms/multi-v2.spdx.json`. That's the fast way to answer "are we affected?" across a fleet when a new CVE lands.
- **SBOM quality varies.** Syft leaves `licenseConcluded` as `NOASSERTION` and reports detected licenses in `licenseDeclared`. SBOMs produced at build time (as Chainguard's apko does) are more accurate than SBOMs generated by scanning afterwards.

## 5. Caveats

- **One scanner.** Other scanners (e.g. Trivy) use different databases and handle distro "won't fix" statuses differently, so counts will differ.
- **Grype ignore rules.** The `single-v2` scan reported 848 ignored matches from Grype's built-in ignore rules, which filter out likely false positives and duplicates.
- **Severity sources differ** between NVD and distro advisories. Debian often rates issues lower than NVD because of how the package is built or used.
