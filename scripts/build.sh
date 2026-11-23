#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
cd "$ROOT_DIR"

command -v node >/dev/null 2>&1 || { echo "error: Node.js is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

BUILT_REVS_FILE="$ROOT_DIR/.cache/built-revs.json"
RUN_START_TS=$(date +%s)

usage() {
  cat <<'EOF'
Usage: sh scripts/build.sh [options] [plugin...]

Pull latest workspace & plugin repositories (auto-cloning any missing ones)
and run unified build.sh for all plugins or specified plugin(s).

Targets (default / "all": all 12 plugins under plugins/*):
  <name>           Case-insensitive match by alias (otp, chat, color, data, doc, json,
                   link, calc, calendar, image, qr, video), short name (funotp),
                   repo name (utools-funotp), or path (plugins/utools-funotp).
                   Supports space- or comma-separated lists (e.g. otp,link).
                   When specific plugin(s) are given, only those plugin repos
                   are synced/checked/built (fast single-plugin workflow).

Options:
  --changed        Only build plugins whose HEAD commit differs from the last
                   successful build (tracked in .cache/built-revs.json), whose
                   working tree is dirty, or whose dist output is missing
  --fast           Fast build-machine mode: sets SKIP_CHECKS=1 for plugin builds
                   (skips lint/typecheck/unit tests while still verifying syntax,
                   versions, and built dist artifacts)
  --reset          Build-machine mirror mode: hard-reset root & target repos
                   to origin/master (discards local tracked modifications)
  --no-pull        Skip git pull on root & existing repos (still clones missing)
  --no-sync        Skip all git pull and sub-repo initialization (fully offline)
  -j, --jobs <N>   Parallel git fetch/clone workers (default: 5)
  --list           List available plugin targets (aliases & build status)
  --dry-run        Print planned sync/check/build commands without executing
  --check-only     Only sync/pull and run consistency check (ws.mjs check)
  --no-check       Skip consistency check (node scripts/ws.mjs check)
  -k, --keep-going Continue building remaining plugins after a failure (default)
  --fail-fast      Abort immediately on the first plugin build failure
  -h, --help       Show this help message

Examples:
  sh scripts/build.sh                    # Sync all repos & build all 12 plugins
  sh scripts/build.sh --fast --changed   # Fast incremental build on build machine
  sh scripts/build.sh otp                # Sync & build only utools-funotp
  sh scripts/build.sh funchat fundoc     # Sync & build only FunChat & FunDoc
  sh scripts/build.sh --no-pull otp,link # Build FunOTP & FunLink without pulling

Passthrough environment variables (honored by individual plugin build.sh scripts):
  SKIP_CHECKS=1      Skip lint/typecheck/test across all plugins (same as --fast)
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
    git -C "$ROOT_DIR" merge --ff-only origin/master
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
FAST_MODE=0
FORCE_RESET=0
AUTO_PULL=1
AUTO_SYNC=1
CHECK_ONLY=0
RUN_CHECK=1
KEEP_GOING=1
SYNC_JOBS=5
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
    --fast)
      FAST_MODE=1
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
    -j|--jobs)
      if [ "$#" -lt 2 ]; then
        echo "error: $1 requires a positive integer argument" >&2
        exit 2
      fi
      shift
      case "$1" in
        ''|*[!0-9]*)
          echo "error: --jobs must be a positive integer (got '$1')" >&2
          exit 2
          ;;
      esac
      if [ "$1" -lt 1 ]; then
        echo "error: --jobs must be >= 1" >&2
        exit 2
      fi
      SYNC_JOBS="$1"
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
    --fail-fast)
      KEEP_GOING=0
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
# Supports case-insensitive aliases (otp, funotp, utools-funotp, plugins/utools-funotp, all)
RESOLVED_INFO=$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const root = process.argv[1];
const rawTargets = process.argv[2]
  .split(/[\n,]+/)
  .map((s) => s.trim())
  .filter(Boolean);
const revsFile = process.argv[3];

let builtRevs = {};
if (fs.existsSync(revsFile)) {
  try {
    builtRevs = JSON.parse(fs.readFileSync(revsFile, "utf8"));
  } catch {
    builtRevs = {};
  }
}

const manifest = JSON.parse(fs.readFileSync(path.join(root, "repos.json"), "utf8"));
const plugins = manifest.repos.filter((repo) => repo.category === "plugin");

let scoped = false;
let selected = [];
if (rawTargets.length > 0 && !rawTargets.some((q) => q.toLowerCase() === "all")) {
  scoped = true;
  const seen = new Set();
  for (const query of rawTargets) {
    const normalized = query.replace(/\/+$/, "").toLowerCase();
    const match = plugins.find((repo) => {
      const name = repo.name.toLowerCase();
      const repoPath = repo.path.toLowerCase();
      const shortName = name.replace(/^utools-/, "");
      const alias = shortName.replace(/^fun/, "");
      return repoPath === normalized || name === normalized || shortName === normalized || alias === normalized;
    });
    if (!match) {
      const aliases = plugins.map((r) => r.name.replace(/^utools-fun/, "")).join(", ");
      console.error(`error: unknown plugin target "${query}". Available: all, ${aliases} (or fun* / utools-fun*)`);
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

console.log(`SCOPED=${scoped ? 1 : 0}`);
for (const repo of selected) {
  const dir = path.join(root, repo.path);
  const shortName = repo.name.replace(/^utools-/, "");
  const alias = shortName.replace(/^fun/, "");
  const hasGit = fs.existsSync(path.join(dir, ".git"));
  const repoState = hasGit ? "ready" : "not-cloned";
  const hasDist = fs.existsSync(path.join(dir, "utools/dist/index.html")) &&
    (!fs.existsSync(path.join(dir, "vite.preload.config.ts")) || fs.existsSync(path.join(dir, "utools/search-core.cjs")));

  let distState = "missing";
  if (hasDist) {
    distState = "built";
    if (hasGit && builtRevs[repo.path]) {
      try {
        const head = execFileSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
        const dirty = execFileSync("git", ["-C", dir, "status", "--porcelain"], { encoding: "utf8" }).trim();
        if (head !== builtRevs[repo.path] || dirty) {
          distState = "stale";
        }
      } catch {
        // ignore git inspection errors for listing
      }
    }
  }
  console.log(`${repo.path}\t${repo.name}\t${shortName}\t${alias}\t${repoState}\t${distState}`);
}
' "$ROOT_DIR" "$TARGETS" "$BUILT_REVS_FILE")

SCOPED=$(printf "%s\n" "$RESOLVED_INFO" | head -n 1 | sed 's/^SCOPED=//')
RESOLVED_LIST=$(printf "%s\n" "$RESOLVED_INFO" | tail -n +2)

if [ "$LIST_ONLY" = 1 ]; then
  if [ -z "$RESOLVED_LIST" ]; then
    echo "(no plugins in repos.json)"
    exit 0
  fi
  printf "%-10s %-14s %-28s %-12s %s\n" "ALIAS" "SHORT" "PATH" "REPO" "DIST"
  printf "%-10s %-14s %-28s %-12s %s\n" "----------" "--------------" "----------------------------" "------------" "-------"
  printf "%s\n" "$RESOLVED_LIST" | while IFS='	' read -r repo_path repo_name short_name alias_name repo_state dist_state; do
    printf "%-10s %-14s %-28s %-12s %s\n" "$alias_name" "$short_name" "$repo_path" "$repo_state" "$dist_state"
  done
  exit 0
fi

TMP_TARGETS=$(mktemp)
TMP_CHANGED=$(mktemp)
TMP_BUILT=$(mktemp)
TMP_FAILED=$(mktemp)
TMP_TO_BUILD=$(mktemp)
trap 'rm -f "$TMP_TARGETS" "$TMP_CHANGED" "$TMP_BUILT" "$TMP_FAILED" "$TMP_TO_BUILD"' EXIT INT TERM
printf "%s\n" "$RESOLVED_LIST" > "$TMP_TARGETS"

# Build space-separated repo path list for scoped ws.mjs sync/check
SCOPED_PATHS=""
if [ "$SCOPED" = 1 ]; then
  SCOPED_PATHS=$(cut -f 1 "$TMP_TARGETS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
fi

# Count uninitialized repositories in scope (all repos when unscoped; selected plugins when scoped)
MISSING_COUNT=$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[1];
const scoped = process.argv[2] === "1";
const targetFile = process.argv[3];
let paths;
if (scoped) {
  paths = fs.readFileSync(targetFile, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")[0]);
} else {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "repos.json"), "utf8"));
  paths = manifest.repos.map((r) => r.path);
}
const missing = paths.filter((p) => !fs.existsSync(path.join(root, p, ".git")));
console.log(missing.length);
' "$ROOT_DIR" "$SCOPED" "$TMP_TARGETS")

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
        echo "[dry-run] git fetch origin --prune && git merge --ff-only origin/master (utools-dev)"
      fi
    fi
    echo "[dry-run] node scripts/ws.mjs sync${SYNC_MODE:+ $SYNC_MODE} --jobs $SYNC_JOBS${SCOPED_PATHS:+ $SCOPED_PATHS}"
  else
    if [ "$MISSING_COUNT" -gt 0 ]; then
      echo "=== [sync] initializing $MISSING_COUNT missing repo(s)${SYNC_MODE:+ & syncing ($SYNC_MODE)} (jobs=$SYNC_JOBS) ==="
    else
      echo "=== [sync] updating ${SCOPED_PATHS:-all sub-repositories} (${SYNC_MODE}, jobs=$SYNC_JOBS) ==="
    fi
    # shellcheck disable=SC2086
    node "$SCRIPT_DIR/ws.mjs" sync ${SYNC_MODE} --jobs "$SYNC_JOBS" --write-changed "$TMP_CHANGED" ${SCOPED_PATHS}
  fi
fi

if [ "$RUN_CHECK" = 1 ]; then
  if [ "$DRY_RUN" = 1 ] && [ "$MISSING_COUNT" -gt 0 ]; then
    echo "[dry-run] node scripts/ws.mjs check${SCOPED_PATHS:+ $SCOPED_PATHS}"
  else
    echo "=== [check] node scripts/ws.mjs check${SCOPED_PATHS:+ $SCOPED_PATHS} ==="
    # shellcheck disable=SC2086
    node "$SCRIPT_DIR/ws.mjs" check ${SCOPED_PATHS}
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  exit 0
fi

if [ -z "$RESOLVED_LIST" ]; then
  echo "error: no plugin targets matched" >&2
  exit 1
fi

# Determine which plugins actually need building (handles --changed accurately via .cache/built-revs.json)
SKIPPED=0
if [ "$CHANGED_ONLY" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  SKIPPED=$(node -e '
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const root = process.argv[1];
const targetsFile = process.argv[2];
const changedFile = process.argv[3];
const revsFile = process.argv[4];
const outFile = process.argv[5];

let builtRevs = {};
if (fs.existsSync(revsFile)) {
  try {
    builtRevs = JSON.parse(fs.readFileSync(revsFile, "utf8"));
  } catch {
    builtRevs = {};
  }
}

const syncChanged = new Set(
  fs.existsSync(changedFile)
    ? fs.readFileSync(changedFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean)
    : []
);

const lines = fs.readFileSync(targetsFile, "utf8").split("\n").filter(Boolean);
const toBuild = [];
let skipped = 0;

for (const line of lines) {
  const repoPath = line.split("\t")[0];
  const dir = path.join(root, repoPath);
  const hasDist = fs.existsSync(path.join(dir, "utools/dist/index.html")) &&
    (!fs.existsSync(path.join(dir, "vite.preload.config.ts")) || fs.existsSync(path.join(dir, "utools/search-core.cjs")));

  let reason = "";
  if (syncChanged.has(repoPath)) {
    reason = "updated";
  } else if (!hasDist) {
    reason = "dist missing";
  } else if (fs.existsSync(path.join(dir, ".git"))) {
    const head = execFileSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    const dirty = execFileSync("git", ["-C", dir, "status", "--porcelain"], { encoding: "utf8" }).trim();
    if (dirty) {
      reason = "working tree dirty";
    } else if (builtRevs[repoPath] && builtRevs[repoPath] !== head) {
      reason = "new commit since last build";
    } else if (!builtRevs[repoPath]) {
      // Built outside build.sh before tracking started; keep fast skip when clean & dist present
      reason = "";
    }
  }

  if (reason) {
    toBuild.push(line);
  } else {
    console.error(`[skip] ${repoPath} (up-to-date and dist already built)`);
    skipped += 1;
  }
}

fs.writeFileSync(outFile, toBuild.join("\n") + (toBuild.length ? "\n" : ""));
console.log(skipped);
' "$ROOT_DIR" "$TMP_TARGETS" "$TMP_CHANGED" "$BUILT_REVS_FILE" "$TMP_TO_BUILD")
else
  cp "$TMP_TARGETS" "$TMP_TO_BUILD"
fi

# Toolchain preflight check (only when there are plugins to actually build)
if [ "$DRY_RUN" = 0 ] && [ -s "$TMP_TO_BUILD" ]; then
  node -e '
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const root = process.argv[1];
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean);
const paths = lines.map((line) => line.split("\t")[0]);

const parseVer = (s) => s.split(".").map((n) => Number.parseInt(n, 10) || 0);
const cmpVer = (a, b) => {
  for (let i = 0; i < 3; i++) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) - (b[i] || 0);
  }
  return 0;
};

let maxNode = null;
let needPnpm = false;
let needNpm = false;

for (const rel of paths) {
  const dir = path.join(root, rel);
  const pkgPath = path.join(dir, "package.json");
  if (!fs.existsSync(pkgPath)) continue;
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  const m = /^>=\s*(\d+\.\d+\.\d+)$/.exec((pkg.engines?.node || "").trim());
  if (m) {
    const v = parseVer(m[1]);
    if (!maxNode || cmpVer(v, maxNode.parts) > 0) {
      maxNode = { raw: m[1], parts: v };
    }
  }
  if (fs.existsSync(path.join(dir, "pnpm-lock.yaml"))) needPnpm = true;
  if (fs.existsSync(path.join(dir, "package-lock.json"))) needNpm = true;
}

const currentNode = parseVer(process.versions.node);
if (maxNode && cmpVer(currentNode, maxNode.parts) < 0) {
  console.error(`error: Node >=${maxNode.raw} is required by selected plugins, found ${process.versions.node}`);
  process.exit(1);
}

if (needPnpm) {
  try {
    const ver = execFileSync("pnpm", ["--version"], { encoding: "utf8" }).trim();
    const major = Number.parseInt(ver.split(".")[0], 10);
    if (!Number.isFinite(major) || major < 12) {
      console.error(`error: pnpm >= 12 is required, found ${ver} (run: corepack enable)`);
      process.exit(1);
    }
  } catch {
    console.error("error: pnpm >= 12 is required by selected plugins (run: corepack enable)");
    process.exit(1);
  }
}

if (needNpm) {
  try {
    execFileSync("npm", ["--version"], { stdio: "ignore" });
  } catch {
    console.error("error: npm is required by selected plugins");
    process.exit(1);
  }
}
' "$ROOT_DIR" "$TMP_TO_BUILD"
fi

if [ "$FAST_MODE" = 1 ]; then
  SKIP_CHECKS=1
  export SKIP_CHECKS
fi

BUILD_CMD="sh build.sh"
if [ "${SKIP_CHECKS:-0}" = "1" ]; then
  BUILD_CMD="SKIP_CHECKS=1 sh build.sh"
fi

TOTAL=0
PASSED=0
FAILED=0
FAILED_LIST=""

while IFS='	' read -r repo_path repo_name short_name alias_name repo_state dist_state; do
  [ -n "$repo_path" ] || continue
  TOTAL=$((TOTAL + 1))

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$CHANGED_ONLY" = 1 ]; then
      echo "[dry-run] (if changed/stale/dist missing) (cd \"$repo_path\" && $BUILD_CMD)"
    else
      echo "[dry-run] (cd \"$repo_path\" && $BUILD_CMD)"
    fi
    PASSED=$((PASSED + 1))
    continue
  fi

  if [ ! -f "$ROOT_DIR/$repo_path/build.sh" ]; then
    echo "error: missing $repo_path/build.sh (run 'node scripts/ws.mjs init $repo_path' first)" >&2
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}${FAILED_LIST:+, }${repo_path}"
    printf "%s\t%s\t%s\n" "$repo_path" "missing build.sh" "0s" >> "$TMP_FAILED"
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
    printf "%s\t%s\t%s\n" "$repo_path" "${ELAPSED}s" "$ROOT_DIR/$repo_path/utools/plugin.json" >> "$TMP_BUILT"

    # Record last successfully built commit SHA for accurate --changed tracking
    node -e '
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const root = process.argv[1];
const repoPath = process.argv[2];
const revsFile = process.argv[3];
const dir = path.join(root, repoPath);
if (!fs.existsSync(path.join(dir, ".git"))) process.exit(0);
const dirty = execFileSync("git", ["-C", dir, "status", "--porcelain"], { encoding: "utf8" }).trim();
if (dirty) process.exit(0);
const head = execFileSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
let data = {};
if (fs.existsSync(revsFile)) {
  try { data = JSON.parse(fs.readFileSync(revsFile, "utf8")); } catch { data = {}; }
}
data[repoPath] = head;
fs.mkdirSync(path.dirname(revsFile), { recursive: true });
fs.writeFileSync(revsFile, JSON.stringify(data, null, 2) + "\n");
' "$ROOT_DIR" "$repo_path" "$BUILT_REVS_FILE"
  else
    STATUS=$?
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    echo "--- [fail] $repo_path (exit $STATUS, ${ELAPSED}s) ---" >&2
    FAILED=$((FAILED + 1))
    FAILED_LIST="${FAILED_LIST}${FAILED_LIST:+, }${repo_path}"
    printf "%s\t%s\t%s\n" "$repo_path" "exit $STATUS" "${ELAPSED}s" >> "$TMP_FAILED"
    if [ "$KEEP_GOING" != 1 ]; then
      echo "" >&2
      echo "Build aborted on $repo_path (--fail-fast enabled)." >&2
      break
    fi
  fi
done < "$TMP_TO_BUILD"

RUN_END_TS=$(date +%s)
RUN_ELAPSED=$((RUN_END_TS - RUN_START_TS))

echo ""
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry-run complete: $TOTAL plugin(s) planned."
  exit 0
fi

echo "=== Build Summary: $PASSED/$TOTAL succeeded, $FAILED failed, $SKIPPED skipped (${RUN_ELAPSED}s) ==="
echo "Succeeded ($PASSED):"
if [ -s "$TMP_BUILT" ]; then
  while IFS='	' read -r ok_path ok_elapsed ok_manifest; do
    echo "  [ok]   $ok_path ($ok_elapsed) -> $ok_manifest"
  done < "$TMP_BUILT"
else
  echo "  (none)"
fi
echo "Failed ($FAILED):"
if [ -s "$TMP_FAILED" ]; then
  while IFS='	' read -r fail_path fail_reason fail_elapsed; do
    echo "  [fail] $fail_path ($fail_reason, $fail_elapsed)"
  done < "$TMP_FAILED"
  exit 1
else
  echo "  (none)"
fi
