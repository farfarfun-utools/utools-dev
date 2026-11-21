#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
cd "$ROOT_DIR"

command -v node >/dev/null 2>&1 || { echo "error: Node.js is required" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sh scripts/build.sh [options] [plugin...]

Initialize missing sub-repositories (if needed) and run unified build.sh
across uTools plugin repositories declared in repos.json.

Targets (default: all plugins under plugins/*):
  <name>           Match by short name (funotp), repo name (utools-funotp),
                   or path (plugins/utools-funotp)

Options:
  --list           List available plugin targets and exit
  --dry-run        Print planned init/check/build commands without executing
  --pull           Also fast-forward clean sub-repositories before building
  --no-sync        Skip automatic initialization of missing sub-repositories
  --check-only     Only init missing repos (unless --no-sync) and run ws.mjs check
  --no-check       Skip workspace consistency check (node scripts/ws.mjs check)
  -k, --keep-going Continue building remaining plugins after a failure
  -h, --help       Show this help message

Passthrough environment variables (honored by individual plugin build.sh scripts):
  SKIP_CHECKS=1      Skip lint/typecheck/test where supported (e.g. funchat)
  RUN_E2E=1          Run Playwright E2E tests (e.g. funcalc)
  RUN_FFMPEG_TEST=1  Run FFmpeg integration tests (funvideo)
EOF
}

LIST_ONLY=0
DRY_RUN=0
DO_PULL=0
AUTO_SYNC=1
CHECK_ONLY=0
RUN_CHECK=1
KEEP_GOING=0
TARGETS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --pull)
      DO_PULL=1
      ;;
    --no-sync)
      AUTO_SYNC=0
      ;;
    --check-only)
      CHECK_ONLY=1
      ;;
    --no-check)
      RUN_CHECK=0
      ;;
    -k|--keep-going)
      KEEP_GOING=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        TARGETS="${TARGETS}${TARGETS:+
}$1"
        shift
      done
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      TARGETS="${TARGETS}${TARGETS:+
}$1"
      ;;
  esac
  shift
done

# Resolve ordered list of plugin targets directly from repos.json
# (works even on a fresh clone before sub-repositories are initialized)
RESOLVED_LIST=$(node -e '
const fs = require("node:fs");
const path = require("node:path");

const root = process.argv[1];
const rawTargets = process.argv[2].split("\n").map((s) => s.trim()).filter(Boolean);

const manifest = JSON.parse(fs.readFileSync(path.join(root, "repos.json"), "utf8"));
const plugins = manifest.repos.filter((repo) => repo.category === "plugin");

let selected = [];
if (rawTargets.length > 0) {
  const seen = new Set();
  for (const query of rawTargets) {
    const normalized = query.replace(/\/+$/, "");
    const match = plugins.find((repo) => {
      const shortName = repo.name.replace(/^utools-/, "");
      return repo.path === normalized || repo.name === normalized || shortName === normalized;
    });
    if (!match) {
      const names = plugins.map((r) => r.name.replace(/^utools-/, "")).join(", ");
      console.error(`error: unknown plugin target "${query}". Available: ${names}`);
      process.exit(2);
    }
    if (!seen.has(match.path)) {
      seen.add(match.path);
      selected.push(match);
    }
  }
} else {
  selected = plugins;
}

for (const repo of selected) {
  const ready = fs.existsSync(path.join(root, repo.path, ".git")) ? "ready" : "not-cloned";
  console.log(`${repo.path}\t${repo.name}\t${ready}`);
}
' "$ROOT_DIR" "$TARGETS")

if [ "$LIST_ONLY" = 1 ]; then
  if [ -z "$RESOLVED_LIST" ]; then
    echo "(no plugins in repos.json)"
    exit 0
  fi
  printf "%-30s %-20s %s\n" "PATH" "NAME" "STATUS"
  printf "%-30s %-20s %s\n" "------------------------------" "--------------------" "----------"
  printf "%s\n" "$RESOLVED_LIST" | while IFS='	' read -r repo_path repo_name repo_state; do
    printf "%-30s %-20s %s\n" "$repo_path" "$repo_name" "$repo_state"
  done
  exit 0
fi

# Auto-initialize sub-repositories if any repo declared in repos.json is missing
MISSING_COUNT=$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(path.join(root, "repos.json"), "utf8"));
const missing = manifest.repos.filter((r) => !fs.existsSync(path.join(root, r.path, ".git")));
console.log(missing.length);
' "$ROOT_DIR")

if [ "$AUTO_SYNC" = 1 ] && { [ "$MISSING_COUNT" -gt 0 ] || [ "$DO_PULL" = 1 ]; }; then
  SYNC_ARGS="sync"
  if [ "$DO_PULL" = 1 ]; then
    SYNC_ARGS="sync --pull"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] node scripts/ws.mjs $SYNC_ARGS"
  else
    if [ "$MISSING_COUNT" -gt 0 ]; then
      echo "=== [init] detected $MISSING_COUNT uninitialized sub-repo(s), cloning via ws.mjs ==="
    else
      echo "=== [sync] updating clean sub-repos via ws.mjs --pull ==="
    fi
    # shellcheck disable=SC2086
    node "$SCRIPT_DIR/ws.mjs" $SYNC_ARGS
  fi
fi

if [ "$RUN_CHECK" = 1 ]; then
  if [ "$DRY_RUN" = 1 ] && [ "$MISSING_COUNT" -gt 0 ]; then
    echo "[dry-run] node scripts/ws.mjs check"
  else
    echo "=== [check] node scripts/ws.mjs check ==="
    node "$SCRIPT_DIR/ws.mjs" check
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  exit 0
fi

if [ -z "$RESOLVED_LIST" ]; then
  echo "error: no plugin targets matched" >&2
  exit 1
fi

TOTAL=0
PASSED=0
FAILED=0
FAILED_LIST=""
TMP_TARGETS=$(mktemp)
trap 'rm -f "$TMP_TARGETS"' EXIT INT TERM
printf "%s\n" "$RESOLVED_LIST" > "$TMP_TARGETS"

while IFS='	' read -r repo_path repo_name repo_state; do
  [ -n "$repo_path" ] || continue
  TOTAL=$((TOTAL + 1))

  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] (cd \"$repo_path\" && sh build.sh)"
    PASSED=$((PASSED + 1))
    continue
  fi

  if [ ! -f "$ROOT_DIR/$repo_path/build.sh" ]; then
    echo "error: missing $repo_path/build.sh (run 'node scripts/ws.mjs init' first)" >&2
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}${FAILED_LIST:+, }${repo_path}"
    if [ "$KEEP_GOING" != 1 ]; then
      exit 1
    fi
    continue
  fi

  echo ""
  echo "=== [build $TOTAL] $repo_path ==="
  START_TS=$(date +%s)
  if (cd "$ROOT_DIR/$repo_path" && sh build.sh); then
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    echo "--- [ok] $repo_path (${ELAPSED}s) ---"
    PASSED=$((PASSED + 1))
  else
    STATUS=$?
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    echo "--- [fail] $repo_path (exit $STATUS, ${ELAPSED}s) ---" >&2
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}${FAILED_LIST:+, }${repo_path}"
    if [ "$KEEP_GOING" != 1 ]; then
      echo "" >&2
      echo "Build aborted on $repo_path (use -k/--keep-going to continue on failure)." >&2
      exit "$STATUS"
    fi
  fi
done < "$TMP_TARGETS"

echo ""
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry-run complete: $TOTAL plugin(s) planned."
  exit 0
fi

echo "Summary: $PASSED/$TOTAL succeeded, $FAILED failed."
if [ "$FAILED" -gt 0 ]; then
  echo "Failed plugins: $FAILED_LIST" >&2
  exit 1
fi
