#!/usr/bin/env bash
# Backfill perf history for OLD commits that predate the perf harness (PR #356,
# bd473c17). For each ref it checks the commit out in a throwaway worktree,
# GRAFTS the current perf harness on top (the harness files are additive and
# don't touch the code being measured), resolves deps, and runs the CI-safe
# `ghent-suite-open` sweep — the ghent corpus is byte-identical from 1.3.0 on,
# so the numbers form a genuine version-over-version trend.
#
# Wall-time is only comparable within one machine, so run every ref in ONE job
# (the perf-backfill workflow does this on a single ubuntu-latest runner, which
# also keeps them comparable to the CI nightly points).
#
# The recorded `rev.sha`/`rev.date` come from the worktree's HEAD, i.e. the
# ORIGINAL old commit (the graft files are untracked, so rev.dirty is true —
# that honestly flags "measured with a grafted harness").
#
# Usage: tool/perf/backfill.sh <history-dir> <ref>...
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HIST="${1:?usage: backfill.sh <history-dir> <ref>...}"; shift || true
[ "$#" -ge 1 ] || { echo "usage: backfill.sh <history-dir> <ref>..." >&2; exit 2; }
mkdir -p "$HIST"; HIST="$(cd "$HIST" && pwd)"

DART=dart; FLUTTER=flutter
if command -v fvm >/dev/null 2>&1; then DART="fvm dart"; FLUTTER="fvm flutter"; fi

# Harness files grafted onto each old commit (additive; from the current tree).
GRAFT=(
  packages/pdf_cos/lib/perf.dart
  packages/pdf_cos/lib/src/perf
  packages/pdf_graphics/tool/perf_sweep.dart
  packages/pdf_graphics/tool/perf_run_context.dart
  tool/perf/scenarios.json
)

ok=0; skipped=""
for ref in "$@"; do
  if ! sha="$(git -C "$ROOT" rev-parse --verify -q "$ref^{commit}")"; then
    echo "!! $ref: not a commit; skip"; skipped="$skipped $ref"; continue
  fi
  wt="$(mktemp -d)/wt"
  echo "== backfill $ref (${sha:0:8}) =="
  if ! git -C "$ROOT" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
    echo "  worktree add failed; skip"; skipped="$skipped $ref"; continue
  fi
  # Graft the harness.
  for f in "${GRAFT[@]}"; do
    mkdir -p "$wt/$(dirname "$f")"
    cp -R "$ROOT/$f" "$wt/$f"
  done
  # Resolve deps, then run the ghent sweep, appending one line tagged with the
  # old rev. Any failure (dep drift / API drift too far back) skips the ref.
  if ! ( cd "$wt" && $FLUTTER pub get ) >/dev/null 2>&1; then
    echo "  pub get failed (dep drift); skip"; skipped="$skipped $ref"
    git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true; continue
  fi
  if ( cd "$wt/packages/pdf_graphics" &&
        $DART run tool/perf_sweep.dart --scenario ghent-suite-open \
          --append-history "$HIST/vm-sweep.ndjson" --out /dev/null ); then
    echo "  measured ok -> $HIST/vm-sweep.ndjson"; ok=$((ok+1))
  else
    echo "  sweep failed (API drift?); skip"; skipped="$skipped $ref"
  fi
  git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
done

echo "backfill done: $ok measured;${skipped:- none skipped}"
