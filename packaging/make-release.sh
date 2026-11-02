#!/bin/bash
#
# make-release.sh — build the release tarball + checksum for a version tag
# Project: KISS-Backup-Client
# Summary: Packs the tree at tag v<X.Y.Z> into dist/kiss-backup-client-<X.Y.Z>.tar.gz (one
#   top-level folder, a VERSION file inside) and writes its SHA-256 next to it, ready to
#   attach to the GitHub release. Builds from the TAG, never the working tree, so what you
#   ship is exactly what is tagged. (GitHub also offers its own auto-generated source
#   archive for every tag; this one is the checksummed, versioned artefact.)
#
# Usage:  packaging/make-release.sh v0.1.0
# Then:   install from it with
#           tar xzf kiss-backup-client-0.1.0.tar.gz && cd kiss-backup-client-0.1.0 && sudo packaging/install.sh
#
set -euo pipefail

TAG="${1:?usage: $0 v<X.Y.Z>}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag must look like v1.2.3" >&2; exit 2; }
cd "$(dirname "$0")/.."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "no tag $TAG — create it first: git tag -a $TAG -m ..." >&2; exit 1; }

VER="${TAG#v}"; NAME="kiss-backup-client-$VER"; OUT="dist"
mkdir -p "$OUT"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$VER" > "$tmp/VERSION"
git archive --format=tar --prefix="$NAME/" "$TAG" > "$tmp/$NAME.tar"
# Deterministic: VERSION gets the tag commit's time and root ownership, so the same tag gives
# the same files everywhere and the same bytes with the same git/tar/gzip versions (archive
# headers differ between versions — e.g. GitHub's Ubuntu runner vs Debian). To compare two
# builds, compare their contents (tar x both, diff -r), not their checksums.
tar --append -f "$tmp/$NAME.tar" --transform "s,^,$NAME/," --mtime="@$(git log -1 --format=%ct "$TAG")" \
    --owner=0 --group=0 --numeric-owner -C "$tmp" VERSION
gzip -9n < "$tmp/$NAME.tar" > "$OUT/$NAME.tar.gz"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo "built $OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"
