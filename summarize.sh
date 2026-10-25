#!/usr/bin/env bash
# Usage: bash summarize.sh reports/before/grype-single-v1.json
f=$1
echo "== $f"
echo "Unique CVEs: $(jq '[.matches[].vulnerability.id] | unique | length' $f)"
echo "-- By severity (unique IDs):"
jq -r '[.matches[] | {id: .vulnerability.id, s: .vulnerability.severity}] | unique
       | group_by(.s)[] | "\(.[0].s)\t\(length)"' $f
echo "-- By package type (OS vs Go):"
jq -r '.matches[].artifact.type' $f | sort | uniq -c
echo "-- Go stdlib matches: $(jq '[.matches[] | select(.artifact.name=="stdlib")] | length' $f)"
echo "-- Fix available: $(jq '[.matches[] | select(.vulnerability.fix.state=="fixed") | .vulnerability.id] | unique | length' $f)"
