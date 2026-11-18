#!/usr/bin/env bash
# Probe Fedora 45 package facts from the public repositories (no container needed).
# Usage: tests/fedora-probe.sh [FIXTURE_DIR]   (default: tests/fixtures)
# Needs: python3, zstd, xz, network access to dl.fedoraproject.org.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/fedora-probe.XXXXXX")
trap 'rm -rf "$work"' EXIT
exec python3 -I "$here/fedora-probe.py" "$work" "${1:-$here/fixtures}"
