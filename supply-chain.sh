#!/usr/bin/env bash
set -euo pipefail
mkdir -p sboms
: > digests.txt

for t in single-v1 multi-v1 single-v2 multi-v2; do
  img=localhost:5001/hello:$t
  echo "=== $t"

  # Push and get the immutable digest reference
  docker push -q "$img"
  ref=$(docker inspect --format '{{index .RepoDigests 0}}' "$img")
  echo "$t $ref" | tee -a digests.txt

  # SBOMs in both standard formats
  syft "docker:$img" -q \
    -o spdx-json="sboms/$t.spdx.json" \
    -o cyclonedx-json="sboms/$t.cdx.json"

  # Sign the image, then attach the SBOM as a signed attestation
  cosign sign   --key cosign.key -y "$ref"
  cosign attest --key cosign.key -y --type spdxjson --predicate "sboms/$t.spdx.json" "$ref"
done
