#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
cd "$ROOT_DIR"

command -v node >/dev/null 2>&1 || { echo "error: Node.js is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sh scripts/build.sh [options] [plugin...]

Pull latest workspace & sub-repositories (auto-cloning any missing ones)
and run unified build.sh across uTools plugin repositories in repos.json.

Targets (default: all plugins under plugins/*):
  <name>           Match by short name (funotp), repo name (utools-funotp),
                   or path (plugins/utools-funotp)

Options:
  --changed        Only build plugins that were cloned/updated in this run
                   or do not have utools/dist/index.html built yet
  --reset          Build-machine mirror mode: hard-reset root & sub-repos to
                   origin/master (discards local tracked modifications)
  --no-pull        Skip git pull on root & existing sub-repos (still clones missing)
  --no-sync        Skip all git pull and sub-repo initialization (fully offline)
  --list           List available plugin targets and exit
  --dry-run        Print planned sync/check/build commands without executing
  --check-only     Only sync/pull and run workspace check (node scripts/ws.mjs check)
  --no-check       Skip workspace consistency check (node scripts/ws.mjs check)
  -k, --keep-going Continue building remaining plugins after a failure
  -h, --help       Show this help message

Passthrough environment variables (honored by individual plugin build.sh scripts):
  SKIP_CHECKS=1      Skip lint/typecheck/test where supported (e.g. funchat)
  RUN_E2E=1          Run Playwright E2E tests (e.g. funcalc)
  RUN_FFMPEG_TEST=1  Run FFmpeg integration tests (funvideo)
EOF
}

# Pre-scan arguments without mutating "$@" so we can self-update utools-dev
# and re-exec cleanly if scripts/build.sh itself changed on origin/master.
PRE_SKIP_SELF_PULL=0
PRE_RESET=0
for arg in "$@"; do
  case "$arg" in
    -h|--help|--list|--dry-run|--no-sync|--no-pull)
      PRE_SKIP_SELF_PULL=1
      ;;
    --reset)
      PRE_RESET=1
      ;;
    --)
      break
      ;;
  esac
done

if [ "$PRE_SKIP_SELF_PULL" = 0 ] && [ "${UTOOLS_BUILD_REEXEC:-0}" != 1 ] && [ -d "$ROOT_DIR/.git" ]; then
  ROOT_BRANCH=$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)
  ROOT_DIRTY=$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)
  OLD_SELF=$(git -C "$ROOT_DIR" rev-parse HEAD:scripts/build.sh 2>/dev/null || true)
  OLD_ROOT=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)

  if [ "$PRE_RESET" = 1 ]; then
    echo "=== [root] syncing utools-dev (--reset -> origin/master) ==="
    git -C "$ROOT_DIR" fetch origin --prune
    git -C "$ROOT_DIR" checkout -B master origin/master
    git -C "$ROOT_DIR" reset --hard origin/master
  elif [ -n "$ROOT_DIRTY" ]; then
    echo "=== [root] skip pull utools-dev (working tree dirty) ==="
  elif [ "$ROOT_BRANCH" != "master" ]; then
    echo "=== [root] skip pull utools-dev (on branch ${ROOT_BRANCH:-detached}, expected master) ==="
  else
    echo "=== [root] pulling latest utools-dev ==="
    git -C "$ROOT_DIR" fetch origin --prune
    git -C "$ROOT_DIR" pull --ff-only origin master
  fi

  NEW_ROOT=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)
  NEW_SELF=$(git -C "$ROOT_DIR" rev-parse HEAD:scripts/build.sh 2>/dev/null || true)
  if [ "$OLD_ROOT" != "$NEW_ROOT" ]; then
    echo "--- [root] updated utools-dev ($OLD_ROOT -> $NEW_ROOT) ---"
  fi
  if [ -n "$OLD_SELF" ] && [ "$OLD_SELF" != "$NEW_SELF" ]; then
    echo "--- [root] scripts/build.sh updated, re-executing ---"
    UTOOLS_BUILD_REEXEC=1 exec sh "$SCRIPT_DIR/build.sh" "$@"
  fi
fi

LIST_ONLY=0
DRY_RUN=0
CHANGED_ONLY=0
FORCE_RESET=0
AUTO_PULL=1
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
    --changed)
      CHANGED_ONLY=1
      ;;
    --reset)
      FORCE_RESET=1
      AUTO_PULL=1
      AUTO_SYNC=1
      ;;
    --no-pull)
      AUTO_PULL=0
      ;;
    --no-sync)
      AUTO_SYNC=0
      AUTO_PULL=0
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

TMP_TARGETS=$(mktemp)
TMP_CHANGED=$(mktemp)
trap 'rm -f "$TMP_TARGETS" "$TMP_CHANGED"' EXIT INT TERM
printf "%s\n" "$RESOLVED_LIST" > "$TMP_TARGETS"

# Count uninitialized sub-repositories declared in repos.json
MISSING_COUNT=$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(path.join(root, "repos.json"), "utf8"));
const missing = manifest.repos.filter((r) => !fs.existsSync(path.join(root, r.path, ".git")));
console.log(missing.length);
' "$ROOT_DIR")

if [ "$AUTO_SYNC" = 1 ] && { [ "$MISSING_COUNT" -gt 0 ] || [ "$AUTO_PULL" = 1 ]; }; then
  if [ "$FORCE_RESET" = 1 ]; then
    SYNC_MODE="--reset"
  elif [ "$AUTO_PULL" = 1 ]; then
    SYNC_MODE="--pull"
  else
    SYNC_MODE=""
  fi

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$AUTO_PULL" = 1 ]; then
      if [ "$FORCE_RESET" = 1 ]; then
        echo "[dry-run] git fetch origin --prune && git reset --hard origin/master (utools-dev)"
      else
        echo "[dry-run] git pull --ff-only origin master (utools-dev)"
      fi
    fi
    echo "[dry-run] node scripts/ws.mjs sync${SYNC_MODE:+ $SYNC_MODE}"
  else
    if [ "$MISSING_COUNT" -gt 0 ]; then
      echo "=== [sync] initializing $MISSING_COUNT missing sub-repo(s)${SYNC_MODE:+ & syncing ($SYNC_MODE)} ==="
    else
      echo "=== [sync] updating sub-repositories (${SYNC_MODE}) ==="
    fi
    if [ -n "$SYNC_MODE" ]; then
      node "$SCRIPT_DIR/ws.mjs" sync "$SYNC_MODE" --write-changed "$TMP_CHANGED"
    else
      node "$SCRIPT_DIR/ws.mjs" sync --write-changed "$TMP_CHANGED"
    fi
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
SKIPPED=0
FAILED=0
FAILED_LIST=""

while IFS='	' read -r repo_path repo_name repo_state; do
  [ -n "$repo_path" ] || continue

  if [ "$CHANGED_ONLY" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    WAS_CHANGED=0
    if grep -Fxq "$repo_path" "$TMP_CHANGED" 2>/dev/null; then
      WAS_CHANGED=1
    fi
    if [ "$WAS_CHANGED" = 0 ] && [ -f "$ROOT_DIR/$repo_path/utools/dist/index.html" ]; then
      echo "[skip] $repo_path (unchanged and dist already built)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  TOTAL=$((TOTAL + 1))

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$CHANGED_ONLY" = 1 ]; then
      echo "[dry-run] (if changed or dist missing) (cd \"$repo_path\" && sh build.sh)"
    else
      echo "[dry-run] (cd \"$repo_path\" && sh build.sh)"
    fi
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

echo "Summary: $PASSED/$TOTAL succeeded, $FAILED failed, $SKIPPED skipped."
if [ "$FAILED" -gt 0 ]; then
  echo "Failed plugins: $FAILED_LIST" >&2
  exit 1
fi
