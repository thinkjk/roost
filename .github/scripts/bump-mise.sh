#!/usr/bin/env bash
# Bumps MISE_VERSION and its sha256 sums in the Dockerfile to the newest mise
# release that is at least MIN_AGE_DAYS old. The sums come from the release's
# SHASUMS256.txt, accepted only if its minisign signature verifies against
# .github/scripts/mise.pub (mise's key, from github.com/jdx/mise/minisign.pub).
# Prints "changed=true|false" (and the version) for GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/../.."
MIN_AGE_DAYS="${MIN_AGE_DAYS:-3}"
api() { curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} "https://api.github.com/$1"; }

tag="$(api 'repos/jdx/mise/releases?per_page=30' | jq -r --argjson age "$MIN_AGE_DAYS" '
  [.[] | select(.draft == false and .prerelease == false)
       | select((.published_at | fromdateiso8601) <= (now - $age * 86400))]
  | first | .tag_name')"
[ -n "$tag" ] && [ "$tag" != null ] || { echo "no mise release older than $MIN_AGE_DAYS days" >&2; exit 1; }
ver="${tag#v}"
cur="$(sed -n 's/^ARG MISE_VERSION=//p' Dockerfile)"
# Only forward: the pinned version may be newer than the age window allows
# (bumped by hand), and that is never undone.
newest="$(printf '%s\n%s\n' "$cur" "$ver" | sort -V | tail -1)"
if [ "$ver" = "$cur" ] || [ "$newest" != "$ver" ]; then echo "changed=false"; exit 0; fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
base="https://github.com/jdx/mise/releases/download/$tag"
curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
curl -fsSL "$base/SHASUMS256.txt.minisig" -o "$tmp/SHASUMS256.txt.minisig"
minisign -Vm "$tmp/SHASUMS256.txt" -p .github/scripts/mise.pub >&2

sum() { awk -v f="./mise-$tag-linux-$1" '$2 == f {print $1}' "$tmp/SHASUMS256.txt"; }
x64="$(sum x64)"; arm64="$(sum arm64)"
[[ "$x64" =~ ^[0-9a-f]{64}$ && "$arm64" =~ ^[0-9a-f]{64}$ ]] || { echo "sums for $tag not found" >&2; exit 1; }

sed -i -e "s/^ARG MISE_VERSION=.*/ARG MISE_VERSION=$ver/" \
       -e "s/^ARG MISE_SHA256_X64=.*/ARG MISE_SHA256_X64=$x64/" \
       -e "s/^ARG MISE_SHA256_ARM64=.*/ARG MISE_SHA256_ARM64=$arm64/" Dockerfile
echo "changed=true"
echo "version=$ver"
echo "bumped mise $cur -> $ver" >&2
