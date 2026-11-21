#!/usr/bin/env node
// Multi-repo workspace helper for farfarfun-utools/utools-dev.
// Commands:
//   node scripts/ws.mjs status          Show git & version status of all repos
//   node scripts/ws.mjs sync [--pull]   Clone missing repos (and fast-forward clean ones with --pull)
//   node scripts/ws.mjs check           Audit cross-repo metadata, manifests, shared code, and tools

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const ROOT = path.resolve(import.meta.dirname, '..');
const MANIFEST_PATH = path.join(ROOT, 'repos.json');
const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));

function git(cwd, args, { allowFail = false } = {}) {
  try {
    return execFileSync('git', ['-C', cwd, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (err) {
    if (allowFail) return null;
    throw err;
  }
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function normalizeUrl(url) {
  return (url || '').trim().replace(/\.git$/, '');
}

function cmdStatus() {
  const rows = [
    ['PATH', 'BRANCH', 'VERSION', 'STATE', 'LAST COMMIT'],
  ];

  for (const repo of manifest.repos) {
    const dir = path.join(ROOT, repo.path);
    if (!fs.existsSync(dir)) {
      rows.push([repo.path, repo.branch, '-', 'MISSING', '-']);
      continue;
    }

    const branch = git(dir, ['branch', '--show-current'], { allowFail: true }) || '(detached)';
    const dirtyLines = (git(dir, ['status', '--porcelain'], { allowFail: true }) || '')
      .split('\n')
      .filter(Boolean);
    const aheadBehind = git(dir, ['rev-list', '--left-right', '--count', '@{u}...HEAD'], { allowFail: true });
    let syncTag = '';
    if (aheadBehind) {
      const [behind, ahead] = aheadBehind.split(/\s+/).map(Number);
      if (ahead > 0 && behind > 0) syncTag = ` +${ahead}/-${behind}`;
      else if (ahead > 0) syncTag = ` +${ahead}`;
      else if (behind > 0) syncTag = ` -${behind}`;
    }

    const state = (dirtyLines.length ? `dirty(${dirtyLines.length})` : 'clean') + syncTag;
    const pkgPath = path.join(dir, 'package.json');
    const version = fs.existsSync(pkgPath) ? (readJson(pkgPath).version || '-') : '-';
    const last = git(dir, ['log', '-1', '--format=%h %ad', '--date=short'], { allowFail: true }) || '-';

    rows.push([repo.path, branch, version, state, last]);
  }

  const widths = rows[0].map((_, idx) => Math.max(...rows.map((row) => row[idx].length)));
  for (let i = 0; i < rows.length; i++) {
    const line = rows[i].map((cell, idx) => cell.padEnd(widths[idx])).join('  ');
    console.log(line);
    if (i === 0) {
      console.log(widths.map((w) => '-'.repeat(w)).join('  '));
    }
  }
}

function cmdSync(args) {
  const doPull = args.includes('--pull');
  for (const repo of manifest.repos) {
    const dir = path.join(ROOT, repo.path);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(path.dirname(dir), { recursive: true });
      console.log(`[clone] ${repo.path} <- ${repo.url}`);
      execFileSync('git', ['clone', '--branch', repo.branch, repo.url, dir], { stdio: 'inherit' });
      continue;
    }

    if (!doPull) {
      console.log(`[ok]    ${repo.path}`);
      continue;
    }

    const branch = git(dir, ['branch', '--show-current'], { allowFail: true });
    const dirty = Boolean(git(dir, ['status', '--porcelain'], { allowFail: true }));
    if (dirty) {
      console.log(`[skip]  ${repo.path} (working tree dirty)`);
      continue;
    }
    if (branch !== repo.branch) {
      console.log(`[skip]  ${repo.path} (on branch ${branch || 'detached'}, expected ${repo.branch})`);
      continue;
    }
    console.log(`[pull]  ${repo.path}`);
    execFileSync('git', ['-C', dir, 'pull', '--ff-only'], { stdio: 'inherit' });
  }
}

async function cmdCheck() {
  const errors = [];
  const warnings = [];
  const fail = (msg) => errors.push(msg);
  const warn = (msg) => warnings.push(msg);

  // 1. Check presence & origin remotes for every manifest repo
  for (const repo of manifest.repos) {
    const dir = path.join(ROOT, repo.path);
    if (!fs.existsSync(dir)) {
      fail(`Missing repo checkout: ${repo.path}`);
      continue;
    }
    const origin = git(dir, ['remote', 'get-url', 'origin'], { allowFail: true });
    if (normalizeUrl(origin) !== normalizeUrl(repo.url)) {
      fail(`${repo.path}: origin "${origin}" does not match manifest "${repo.url}"`);
    }
  }

  // 2. Load index README and current-state doc for cross-checking
  const indexReadmePath = path.join(ROOT, 'index/utools-plugins/README.md');
  const indexReadme = fs.existsSync(indexReadmePath) ? fs.readFileSync(indexReadmePath, 'utf8') : '';
  const stateDocPath = path.join(ROOT, 'skills/utools-plugin-development/references/current-state.md');
  const stateDoc = fs.existsSync(stateDocPath) ? fs.readFileSync(stateDocPath, 'utf8') : '';

  // Parse window heights table from current-state.md: | FunQR | Vue/Vite | 720 | ...
  const stateHeights = new Map();
  for (const line of stateDoc.split('\n')) {
    const match = line.match(/^\|\s*(Fun[A-Za-z]+)\s*\|[^|]+\|\s*(\d+)\s*\|/);
    if (match) {
      stateHeights.set(match[1].toLowerCase(), Number(match[2]));
    }
  }

  // 3. Check all plugins
  const plugins = manifest.repos.filter((r) => r.category === 'plugin');
  for (const repo of plugins) {
    const dir = path.join(ROOT, repo.path);
    if (!fs.existsSync(dir)) continue;

    const pkgPath = path.join(dir, 'package.json');
    const pluginJsonPath = path.join(dir, 'utools/plugin.json');
    if (!fs.existsSync(pkgPath)) {
      fail(`${repo.path}: missing package.json`);
      continue;
    }
    if (!fs.existsSync(pluginJsonPath)) {
      fail(`${repo.path}: missing utools/plugin.json`);
      continue;
    }

    const pkg = readJson(pkgPath);
    const plugin = readJson(pluginJsonPath);

    if (pkg.version !== plugin.version) {
      fail(`${repo.path}: version mismatch (package.json=${pkg.version}, plugin.json=${plugin.version})`);
    }
    if (!pkg.name?.startsWith('@farfarfun/utools-')) {
      fail(`${repo.path}: package.json#name should use @farfarfun/utools-* scope (got "${pkg.name}")`);
    }
    if (plugin.main !== 'dist/index.html') {
      fail(`${repo.path}: plugin.json#main should be "dist/index.html" (got "${plugin.main}")`);
    }

    // Check referenced assets in utools/
    const utoolsDir = path.join(dir, 'utools');
    for (const rel of [plugin.logo, plugin.preload].filter(Boolean)) {
      if (!fs.existsSync(path.join(utoolsDir, rel))) {
        fail(`${repo.path}: missing referenced utools/${rel}`);
      }
    }
    for (const feat of plugin.features || []) {
      if (feat.icon && !fs.existsSync(path.join(utoolsDir, feat.icon))) {
        fail(`${repo.path}: missing feature icon utools/${feat.icon}`);
      }
    }

    // Required engineering entrypoints
    for (const required of ['build.sh', 'identity.json', '.github/workflows/ci.yml', '.github/workflows/release.yml']) {
      if (!fs.existsSync(path.join(dir, required))) {
        fail(`${repo.path}: missing ${required}`);
      }
    }

    // Index coverage
    if (indexReadme && !indexReadme.includes(repo.name)) {
      fail(`index/utools-plugins/README.md does not list ${repo.name}`);
    }

    // current-state.md window height check
    const shortKey = repo.name.replace(/^utools-/, '').toLowerCase();
    const docHeight = stateHeights.get(shortKey);
    const actualHeight = plugin.pluginSetting?.height;
    if (docHeight !== undefined && actualHeight !== undefined && docHeight !== actualHeight) {
      fail(`skills/.../current-state.md height mismatch for ${repo.name}: doc=${docHeight}, plugin.json=${actualHeight}`);
    }
  }

  // 4. Check apps/utools-mobile shared code parity & build.sh
  const mobileDir = path.join(ROOT, 'apps/utools-mobile');
  if (fs.existsSync(mobileDir)) {
    if (!fs.existsSync(path.join(mobileDir, 'build.sh'))) {
      fail('apps/utools-mobile: missing build.sh');
    }

    const otpPluginDir = path.join(ROOT, 'plugins/utools-funotp');
    const linkPluginDir = path.join(ROOT, 'plugins/utools-funlink');
    const noticePath = path.join(mobileDir, 'NOTICE.md');
    const notice = fs.existsSync(noticePath) ? fs.readFileSync(noticePath, 'utf8') : '';

    if (fs.existsSync(otpPluginDir)) {
      const otpVersion = readJson(path.join(otpPluginDir, 'package.json')).version;
      if (!notice.includes(`utools-funotp\` v${otpVersion}`)) {
        warn(`apps/utools-mobile/NOTICE.md does not reference utools-funotp v${otpVersion}`);
      }
      const mobileOtpDir = path.join(mobileDir, 'src/shared/otp');
      for (const file of fs.readdirSync(mobileOtpDir).filter((f) => f.endsWith('.ts'))) {
        const src = path.join(otpPluginDir, 'src/lib', file);
        const dst = path.join(mobileOtpDir, file);
        if (!fs.existsSync(src)) {
          fail(`apps/utools-mobile: shared otp/${file} has no counterpart in utools-funotp/src/lib/`);
        } else if (fs.readFileSync(src, 'utf8') !== fs.readFileSync(dst, 'utf8')) {
          fail(`apps/utools-mobile: src/shared/otp/${file} drifted from plugins/utools-funotp/src/lib/${file}`);
        }
      }
    }

    if (fs.existsSync(linkPluginDir)) {
      const linkVersion = readJson(path.join(linkPluginDir, 'package.json')).version;
      if (!notice.includes(`utools-funlink\` v${linkVersion}`)) {
        warn(`apps/utools-mobile/NOTICE.md does not reference utools-funlink v${linkVersion}`);
      }
      const mobileLinkDir = path.join(mobileDir, 'src/shared/link');
      for (const file of fs.readdirSync(mobileLinkDir).filter((f) => f.endsWith('.ts'))) {
        const src = path.join(linkPluginDir, 'src/lib', file);
        const dst = path.join(mobileLinkDir, file);
        if (!fs.existsSync(src)) {
          fail(`apps/utools-mobile: shared link/${file} has no counterpart in utools-funlink/src/lib/`);
          continue;
        }
        const srcText = fs.readFileSync(src, 'utf8');
        const dstText = fs.readFileSync(dst, 'utf8');
        if (file === 'types.ts') {
          // Mobile intentionally omits desktop-only WebDavConfig / MenuItem / FunLinkBridge tail
          if (!srcText.startsWith(dstText)) {
            fail('apps/utools-mobile: src/shared/link/types.ts diverged from prefix of plugins/utools-funlink/src/lib/types.ts');
          }
        } else if (srcText !== dstText) {
          fail(`apps/utools-mobile: src/shared/link/${file} drifted from plugins/utools-funlink/src/lib/${file}`);
        }
      }
    }
  }

  // 5. Check tools/utools-shots syntax & plugin root resolution
  const shotsDir = path.join(ROOT, 'tools/utools-shots');
  if (fs.existsSync(shotsDir)) {
    const mjsFiles = [
      ...fs.readdirSync(shotsDir).filter((f) => f.endsWith('.mjs')).map((f) => path.join(shotsDir, f)),
      ...fs.readdirSync(path.join(shotsDir, 'apps')).filter((f) => f.endsWith('.mjs')).map((f) => path.join(shotsDir, 'apps', f)),
    ];
    for (const file of mjsFiles) {
      try {
        execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
      } catch (err) {
        fail(`tools/utools-shots: syntax error in ${path.relative(ROOT, file)}: ${err.stderr?.toString().trim()}`);
      }
    }

    try {
      const sharedMod = await import(path.join(shotsDir, 'shared.mjs'));
      if (typeof sharedMod.resolvePluginRoot === 'function') {
        for (const name of ['utools-funchat', 'utools-fundoc', 'utools-funlink', 'utools-funotp']) {
          const resolved = sharedMod.resolvePluginRoot(name);
          if (!fs.existsSync(path.join(resolved, 'utools/plugin.json'))) {
            fail(`tools/utools-shots: resolvePluginRoot("${name}") -> ${resolved} missing utools/plugin.json`);
          }
        }
      } else {
        fail('tools/utools-shots/shared.mjs is missing resolvePluginRoot()');
      }
    } catch (err) {
      fail(`tools/utools-shots: failed to validate plugin resolution: ${err.message}`);
    }
  }

  // Report
  for (const w of warnings) console.warn(`WARN:  ${w}`);
  for (const e of errors) console.error(`ERROR: ${e}`);

  if (errors.length === 0) {
    console.log(`OK: checked ${manifest.repos.length} repos (${plugins.length} plugins), 0 errors, ${warnings.length} warnings.`);
  } else {
    console.error(`FAILED: ${errors.length} error(s), ${warnings.length} warning(s).`);
    process.exit(1);
  }
}

const [command = 'status', ...rest] = process.argv.slice(2);
switch (command) {
  case 'status':
    cmdStatus();
    break;
  case 'sync':
    cmdSync(rest);
    break;
  case 'check':
    await cmdCheck();
    break;
  default:
    console.error('Usage: node scripts/ws.mjs <status|sync [--pull]|check>');
    process.exit(2);
}
