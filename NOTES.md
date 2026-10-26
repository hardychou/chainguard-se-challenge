# Journey Notes

A log of decisions, problems I hit and how I solved them. Format: **Problem → Cause → Fix → Lesson.**

## Decisions

| Decision | Choice | Reasoning / tradeoff |
|---|---|---|
| Where to run | DigitalOcean cloud VM | My laptop is a corporate device, so I kept this work off it entirely. A cloud VM is isolated, disposable and easy to demo. DigitalOcean and Linode cost the same ($48/mo, billed hourly), and DigitalOcean's docs tipped it. |
| VM size | 4 vCPU / 8 GB / 160 GB | Estimated peak ≈ 5–6 GB RAM (kind + `golang` build + scan). 4 GB would risk OOM kills, and 16 GB adds nothing. Disk use was ≈ 15–25 GB. |
| Network exposure | Firewall allows only port 22; services bound to `127.0.0.1` | Never expose an unauthenticated registry. SSH tunnels for demos. |
| User | Worked as `root` on the VM | A shortcut for a throwaway lab VM. In production I'd use a non-root user with sudo, and rootless Docker or Podman. The containers themselves run as nonroot. |
| Registry | `registry:3` | The current kind local-registry script uses it. It's the maintained major version of CNCF Distribution and works the same for push/pull/cosign. |
| Multi-stage runtime base (v1) | `distroless/static` | Well-known minimal base, used to isolate the effect of multi-stage itself |
| Remediation base (v2) | Chainguard `go` + `static` | Minimal, continuously rebuilt, signed, ships SBOMs; nonroot by default |
| Signing | Key-based cosign | Simple and works for a local registry. **Tradeoff:** a long-lived private key must be protected. Keyless signing (OIDC + Fulcio + Rekor) is the better production choice. |
| Deploy reference | Digest (`@sha256:`), not tag | Tags are mutable; the digest guarantees the cluster runs exactly what was scanned and signed |

## Problems & fixes

### 1. DigitalOcean: "SSH key with fingerprint already exists"
- **Cause:** the key was already saved on the account.
- **Fix:** selected the existing key when creating the droplet instead of adding it again.

### 2. `kubectl get nodes` tried to reach `localhost:8080`
- **Cause:** no kubeconfig. The kind cluster had never been created (`kind get clusters` → none). With no config, kubectl falls back to `localhost:8080`.
- **Fix:** ran the kind local-registry script to create the registry and cluster.
- **Lesson:** kubeconfig is per user (`~/.kube/config`). Mixing users (root vs a normal user) causes the same symptom.

### 3. Image not visible at `http://<droplet-ip>:5001/hello:single-v1`
- **Cause:** three separate things:
  - `docker build` only builds locally; the tag names a destination but doesn't push.
  - The registry is bound to `127.0.0.1` and the firewall allows only port 22.
  - A registry is an API (`/v2/...`), not a website.
- **Fix:** `docker push`, then `curl localhost:5001/v2/_catalog` and `/v2/hello/tags/list`, viewed in a browser through an SSH tunnel.

### 4. `fatal: not a git repository`
- **Cause:** ran git from `~` instead of `~/cg-repo`.
- **Fix:** `cd ~/cg-repo` and `git init -b main`. **Never** `git init` in a home directory, or `git add .` would pick up SSH keys and configs.

### 5. Local app test: `curl: Failed to connect to localhost port 8080`
- **Cause:** the server wasn't running. `&` backgrounds a process only in the current shell, and the build/run line hadn't run in that session.
- **Fix:** build, run the server with its output logged, check the log, then `curl`.

### 6. v2 container test: `curl localhost:8081/8082` failed to connect
- **Cause:** <!-- TODO: what `docker ps -a` / `docker logs` showed -->
- **Fix:** <!-- TODO -->

### 7. `.gitignore` didn't exist when adding `cosign.key`
- **Cause:** an earlier step that should have created it never ran in the repo folder.
- **Fix:** created `.gitignore` with `*.key`, which also covers `other.key` from the wrong-key test, and checked `git log --all -- '*.key'` to make sure no private key was ever committed.

### 8. Grype output: "848 ignored"
- **Cause:** Grype's built-in ignore rules suppress likely false positives and duplicates.
- **Lesson:** scanner counts depend on tool configuration. That's one reason different scanners disagree.

### 9. SBOM license counts looked wrong (multi-v2 = "1 license")
- **Cause:** Syft sets `licenseConcluded` to `NOASSERTION`; detected licenses are in `licenseDeclared`.
- **Fix:** queried `licenseDeclared` instead.
- **Lesson:** SBOM quality depends on the tool and the available metadata.

### 10. `kubectl get endpoints`: "v1 Endpoints is deprecated in v1.33+"
- **Fix:** used `kubectl get endpointslices -l kubernetes.io/service-name=hello`, the current API.

### 11. `kubectl run ... error: --image is required`
- **Cause:** `$REF_OLD` was empty. The line that set it was skipped, and shell variables don't survive a new SSH session.
- **Fix:** set it again from `digests.txt` and `echo` it before use.

### 12. Root-image negative test stuck in `ContainerCreating`
- **Cause:** it was still pulling the 409 MB `single-v1` image. The `runAsNonRoot` check happens only after the pull.
- **Result:** it ended in `CreateContainerConfigError: container has runAsNonRoot and image will run as root`, which is the expected rejection.
- **Lesson:** image size directly affects pull time, and therefore scaling and recovery speed.

### 13. `git push`: "Repository not found", then 403
- **Cause:** the fine-grained personal access token didn't have effective write access to the repo. GitHub reports "not found" for repos a token can't see.
- **Fix:** switched to `gh auth login` (browser device flow) plus `gh auth setup-git`, then deleted the unused token.

### 14. GitHub warning: `grype-single-v1.json` is 51.7 MB
- **Cause:** a full JSON report for an image with 817 CVEs. GitHub warns at 50 MB and rejects files over 100 MB.
- **Fix:** gzipped it (`reports/before/grype-single-v1.json.gz`). The `.txt` table version stays readable on GitHub.

## Things I'd do with more time
- An admission policy requiring valid cosign signatures (policy-controller or Kyverno)
- Build the image with melange + apko, using the repo's own `melange.yaml`/`apko.yaml`
- Run Trivy alongside Grype and explain where the counts differ
- Keyless signing from a CI pipeline, with SLSA provenance
