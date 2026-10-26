# Chainguard Solutions Engineer Technical Challenge

Containerizing the Go app from [`chainguard-dev/hello-melange-apko`](https://github.com/chainguard-dev/hello-melange-apko), analyzing and fixing its security posture, securing the supply chain, and deploying it as a standalone container and on Kubernetes.

## TL;DR

| | Starting point (`single-v1`) | End result (`multi-v2`) |
|---|---:|---:|
| Image size | 1.65 GB | <!-- TODO: from `docker images` --> |
| Unique CVEs (Grype) | **817** (50 Critical, 268 High) | **0** |
| Packages in SBOM | 261 | 25 |
| Runs as | root | nonroot (UID 65532) |
| Shell / package manager | Yes | No |
| Signed + SBOM attested | — | Yes (cosign) |

Getting from 817 to 0 took **two separate fixes**. Neither one was enough by itself:

1. **A multi-stage build onto a minimal base** removed the OS layer (817 → 72 CVEs, 1.65 GB → 16.1 MB) without changing any code.
2. **Patching Go and the app's dependencies** removed the CVEs compiled into the binary (72 → 0) once combined with a Chainguard base.

Patching the app but keeping a traditional base (`single-v2`) still left **266 CVEs**. Only 1 of them had a fix available.

---

## Environment & Architecture

```
DigitalOcean Droplet (SGP1, Ubuntu 24.04 LTS, 4 vCPU / 8 GB / 160 GB)
└── Docker Engine
    ├── kind cluster ("kind-control-plane" node container)
    │     └── containerd ──pulls──► localhost:5001  (mapped via hosts.toml)
    └── kind-registry (registry:3 / CNCF Distribution)
          127.0.0.1:5001  ◄── docker push / cosign sign / cosign attest
```

Access is SSH only. The DigitalOcean cloud firewall allows inbound port 22 and nothing else, and the registry and app ports are bound to `127.0.0.1`. Demos are reached through SSH tunnels (`ssh -L`).

### Tool choices and reasoning

| Need | Choice | Why | Alternatives considered |
|---|---|---|---|
| VM | DigitalOcean Droplet | My laptop is a corporate device, so I used an isolated, disposable cloud VM. It bills hourly (≈ $0.07/h), has good docs, and the Singapore region is close to me. | Linode (same price), Hetzner (no longer cheaper after 2026 repricing), local VM (not possible) |
| VM size | 4 vCPU / 8 GB | Peak memory is ≈ 5–6 GB with kind, a `golang` build and a scan running together. 4 GB risks OOM kills. | 4 GB + swap |
| Container engine | Docker Engine | Most widely used, and kind runs on it | Podman, containerd + nerdctl |
| Kubernetes | kind | Runs as containers on Docker, starts in about a minute, easy to rebuild, and has a documented local-registry setup | k3d, minikube, k3s |
| Registry | `registry:3` (CNCF Distribution v3) | The simplest OCI-compliant registry and the current maintained major version. It stores cosign signatures and attestations as OCI artifacts. | `kind load` (no registry, so nothing to sign), Harbor (too heavy for one VM), Zot, GHCR/Docker Hub (public internet) |
| CVE scanner | Grype | Fast, free, scans images and SBOMs, JSON output is easy to script | Trivy, Docker Scout |
| Reachability | govulncheck | Reports only vulnerabilities the code actually calls, which helps separate real risk from noise | — |
| SBOM | Syft (SPDX + CycloneDX) | Pairs with Grype and outputs both major formats | Trivy, `docker sbom` |
| Signing | Cosign (Sigstore) | Industry standard; signatures and attestations live next to the image in the registry | Notation (Notary v2) |

**Tool versions** (from `docker version`, `kind version`, `grype version`, `syft version`, `cosign version`, `go version`):
<!-- TODO: paste versions -->

---

## Repository layout

```
.
├── README.md                  ← you are here (methodology)
├── NOTES.md                   ← journey log: problems hit and how they were solved
├── main.go, go.mod, go.sum    ← the app (go.mod patched in Part 3)
├── Dockerfile.single          ← Part 1: single-stage, golang:1.18
├── Dockerfile.multi           ← Part 1: multi-stage, golang:1.18 → distroless/static
├── Dockerfile.single-v2       ← Part 3: single-stage, patched Go + deps
├── Dockerfile.multi-v2        ← Part 3: multi-stage, chainguard/go → chainguard/static
├── .dockerignore
├── summarize.sh               ← summarizes Grype JSON (severity, package type, fixable)
├── supply-chain.sh            ← push → SBOM → sign → attest for all images
├── digests.txt                ← immutable digest of every pushed image
├── cosign.pub                 ← public key to verify signatures (private key NOT committed)
├── reports/
│   ├── README.md              ← findings: before/after tables and analysis
│   ├── before/                ← Grype reports for v1 images (+ govulncheck)
│   └── after/                 ← Grype reports for v2 images
├── sboms/                     ← SPDX + CycloneDX SBOM for each image
└── k8s/
    └── hello.yaml             ← Namespace (PSS restricted), Deployment, Service
```

---

## Methodology

### Part 1: Containerization

| Image | Dockerfile | Build → Runtime base | Notes |
|---|---|---|---|
| `single-v1` | `Dockerfile.single` | `golang:1.18` | Compiler, Debian userland, shell and source all ship to production; runs as root |
| `multi-v1` | `Dockerfile.multi` | `golang:1.18` → `gcr.io/distroless/static-debian12:nonroot` | Only the binary is copied into the final image; nonroot; no shell |

Design choices in the multi-stage build:
- `CGO_ENABLED=0` produces a static binary, so it runs on a base with no libc.
- `-trimpath -ldflags="-s -w"` strips local paths and debug symbols, making the binary smaller and reproducible.
- `go.mod`/`go.sum` are copied and downloaded first, so the dependency layer is cached between builds.
- `.dockerignore` keeps reports, SBOMs, keys and `.git` out of the build context.

Original dependencies were deliberately left at Go 1.18 and Gin 1.8.1 so the "before" scans show the real starting point.

### Part 2: Security analysis

```bash
grype db update
grype docker:localhost:5001/hello:<tag> -o table > reports/before/grype-<tag>.txt
grype docker:localhost:5001/hello:<tag> -o json  > reports/before/grype-<tag>.json
bash summarize.sh reports/before/grype-<tag>.json
```
The `docker:` prefix scans the image in the local Docker store before it's pushed. Results and analysis are in [`reports/README.md`](reports/README.md).

### Part 3: Remediation

1. **Patch the app:** raised the `go` directive from 1.18 to the current Go release, ran `go get -u ./...` and `go mod tidy`, and confirmed with a local build, a `curl` test, and `govulncheck ./...`.
2. **Update the bases:**
   - `single-v2`: current `golang` image. This isolates the effect of patching the app alone.
   - `multi-v2`: built on `cgr.dev/chainguard/go:latest` and run on `cgr.dev/chainguard/static:latest`. These are minimal Wolfi-based images, rebuilt continuously, signed, and shipped with SBOMs. Nonroot by default.
3. **Rescan** into `reports/after/`.

### Part 4: Supply chain security (`supply-chain.sh`)

For each of the 4 images:
1. `docker push` to `localhost:5001`, then record the **digest** in `digests.txt`.
2. `syft` → `sboms/<tag>.spdx.json` and `sboms/<tag>.cdx.json`.
3. `cosign sign --key cosign.key <digest>`.
4. `cosign attest --key cosign.key --type spdxjson --predicate sboms/<tag>.spdx.json <digest>`.

Verification:
```bash
cosign verify --key cosign.pub <digest>
cosign verify-attestation --key cosign.pub --type spdxjson <digest>
cosign tree <digest>
```
Negative tests:
- An **unsigned** image (`localhost:5001/unsigned:test`) fails with `no signatures found`.
- A **signed image checked against a different key** also fails. A signature only means something if it comes from a key you trust.

Transparency log: <!-- TODO: state whether you used the public Rekor log or --tlog-upload=false, and why -->

### Part 5: Deployment

**Standalone (hardened):**
```bash
docker run -d --name hello-standalone -p 127.0.0.1:8080:8080 \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --restart unless-stopped -e GIN_MODE=release <multi-v2 digest>
curl localhost:8080   # Hello World!
```

**Kubernetes** (`k8s/hello.yaml`, image injected by digest):
- Namespace enforces **Pod Security Standards: restricted**.
- 2 replicas; `runAsNonRoot`, UID/GID 65532, `readOnlyRootFilesystem`, all capabilities dropped, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.
- `automountServiceAccountToken: false`, since the app never calls the Kubernetes API.
- CPU/memory requests and limits; readiness and liveness probes on `/`.

```bash
sed "s|IMAGE_REF|$REF|" k8s/hello.yaml | kubectl apply -f -
kubectl -n hello rollout status deploy/hello
kubectl -n hello get endpointslices -l kubernetes.io/service-name=hello   # 2 pod IPs
kubectl -n hello port-forward svc/hello 9090:80 & curl localhost:9090
```

**Validation:**
- Both deployments return `Hello World!`.
- The Service routes to both replicas.
- Running pods use the exact signed `@sha256:` digest.
- **Negative test:** running `single-v1`, which runs as root, under `runAsNonRoot` fails with `CreateContainerConfigError: container has runAsNonRoot and image will run as root`.

---

## How to reproduce

```bash
# 1. Tooling (Ubuntu 24.04): Docker, Go, kubectl, kind, cosign, syft, grype
# 2. kind cluster + local registry (kind "local registry" guide)
# 3. Build
docker build -f Dockerfile.single    -t localhost:5001/hello:single-v1 .
docker build -f Dockerfile.multi     -t localhost:5001/hello:multi-v1 .
docker build -f Dockerfile.single-v2 --build-arg GO_VERSION=<1.xx> -t localhost:5001/hello:single-v2 .
docker build -f Dockerfile.multi-v2  -t localhost:5001/hello:multi-v2 .
# 4. Scan:   grype docker:localhost:5001/hello:<tag> -o json > reports/<phase>/grype-<tag>.json
# 5. Supply chain:  cosign generate-key-pair && bash supply-chain.sh
# 6. Deploy:  see Part 5 above
```
Note: the `v1` images are pinned to Go 1.18 only through the original `go.mod`. To rebuild them, check out the tag `before-remediation`.

---

## Production challenges with traditional container builds

- **CVE noise and triage fatigue.** `single-v2` still reports 266 CVEs after the app was patched, and 265 of them have no fix available. A security team can only accept, suppress or argue about them.
- **Fixes exist but aren't applied.** All 72 CVEs in `multi-v1` had fixes available. The gap is rebuild cadence, not patch availability.
- **Base images go stale quietly.** A clean scan today isn't clean next month. Staying at zero needs continuous rebuilds of both the base and the app.
- **Attack surface.** Shells, package managers and compilers in production images give attackers tools.
- **Provenance.** Without signatures and SBOMs, you can't prove what's running or answer "are we affected?" quickly when the next Log4Shell-style vulnerability lands.
- **Pull time.** The 409 MB compressed `single-v1` took noticeably longer to pull into the cluster than the ~3.6 MB `multi` images, which affects scaling, node replacement and recovery.

## What I'd add for production

- **Admission control that requires a valid signature** (Sigstore policy-controller or Kyverno), so unsigned images are rejected automatically and not just in a manual `cosign verify`.
- **Keyless signing** (OIDC → Fulcio → Rekor) in CI, so there's no long-lived private key to protect or rotate.
- **SLSA build provenance** attestations generated in CI.
- **Automated rebuilds** on base-image or dependency updates (Renovate/Dependabot plus scheduled rebuilds), with scanning as a CI gate.
- **VEX** statements to mark non-exploitable findings and cut triage noise.
- **NetworkPolicies**, Ingress with TLS, an HPA, and running workloads as a non-root user on the host too.
