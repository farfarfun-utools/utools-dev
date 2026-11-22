#!/usr/bin/env node
// Multi-repo workspace helper for farfarfun-utools/utools-dev.
// Commands:
//   node scripts/ws.mjs status                                     Show git & version status of root + all sub-repos
//   node scripts/ws.mjs init [--jobs N] [repo...]                  Clone missing repos (alias of sync)
//   node scripts/ws.mjs sync [--pull|--reset] [--jobs N] [repo...] Clone missing repos and optionally update existing ones
//   node scripts/ws.mjs prune [--dry-run]                          Delete local branches already merged into default branch
//   node scripts/ws.mjs check [repo...]                            Audit cross-repo metadata, manifests, shared code, and tools

import fs from 'node:fs';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
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

async function gitAsync(cwd, args, { allowFail = false } = {}) {
  try {
    const { stdout } = await execFileAsync('git', ['-C', cwd, ...args], {
      encoding: 'utf8',
      maxBuffer: 4 * 1024 * 1024,
    });
    return stdout.trim();
  } catch (err) {
    if (allowFail) return null;
    const msg = (err.stderr || err.stdout || err.message || '').trim().split('\n')[0];
    throw new Error(msg || `git ${args.join(' ')} failed`);
  }
}

async function cloneAsync(url, branch, dir) {
  try {
    await execFileAsync('git', ['clone', '--branch', branch, url, dir], {
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
    });
  } catch (err) {
    const msg = (err.stderr || err.stdout || err.message || '').trim().split('\n')[0];
    throw new Error(msg || `git clone ${url} failed`);
  }
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function normalizeUrl(url) {
  return (url || '').trim().replace(/\.git$/, '');
}

function matchRepo(repo, query) {
  const q = query.trim().replace(/\/+$/, '').toLowerCase();
  if (!q) return false;
  const name = repo.name.toLowerCase();
  const repoPath = repo.path.toLowerCase();
  const withoutUtools = name.replace(/^utools-/, '');
  const withoutFun = withoutUtools.replace(/^fun/, '');
  return (
    repoPath === q ||
    name === q ||
    withoutUtools === q ||
    (repo.category === 'plugin' && withoutFun === q)
  );
}

function selectRepos(queries) {
  const flat = queries.flatMap((q) => q.split(',')).map((s) => s.trim()).filter(Boolean);
  if (flat.length === 0 || flat.some((q) => q.toLowerCase() === 'all')) {
    return manifest.repos;
  }
  const selected = [];
  const seen = new Set();
  for (const query of flat) {
    const found = manifest.repos.find((repo) => matchRepo(repo, query));
    if (!found) {
      const names = manifest.repos.map((r) => r.name.replace(/^utools-/, '')).join(', ');
      console.error(`error: unknown repo target "${query}". Available: ${names}`);
      process.exit(2);
    }
    if (!seen.has(found.path)) {
      seen.add(found.path);
      selected.push(found);
    }
  }
  return selected;
}

function parseSyncArgs(args) {
  let doReset = false;
  let doPull = false;
  let jobs = 5;
  let changedFile = null;
  const targets = [];

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--reset') {
      doReset = true;
      doPull = true;
    } else if (arg === '--pull') {
      doPull = true;
    } else if (arg === '--jobs' || arg === '-j') {
      const next = args[++i];
      if (!next || !/^\d+$/.test(next) || Number.parseInt(next, 10) < 1) {
        console.error(`error: ${arg} requires a positive integer (got "${next ?? ''}")`);
        process.exit(2);
      }
      jobs = Number.parseInt(next, 10);
    } else if (arg === '--write-changed') {
      const next = args[++i];
      if (!next) {
        console.error('error: --write-changed requires a file path');
        process.exit(2);
      }
      changedFile = next;
    } else if (arg.startsWith('-')) {
      console.error(`error: unknown sync option "${arg}"`);
      process.exit(2);
    } else {
      targets.push(arg);
    }
  }
  return { doReset, doPull, jobs, changedFile, targets };
}

async function mapPool(items, concurrency, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  const count = Math.min(Math.max(concurrency, 1), items.length || 1);
  await Promise.all(
    Array.from({ length: count }, async () => {
      while (true) {
        const idx = cursor++;
        if (idx >= items.length) return;
        results[idx] = await worker(items[idx], idx);
      }
    }),
  );
  return results;
}

function getRepoStatusRow(displayPath, dir, expectedBranch) {
  if (!fs.existsSync(dir)) {
    return [displayPath, expectedBranch, '-', 'MISSING', '-'];
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
  return [displayPath, branch, version, state, last];
}

function cmdStatus() {
  const rows = [
    ['PATH', 'BRANCH', 'VERSION', 'STATE', 'LAST COMMIT'],
    getRepoStatusRow('. (utools-dev)', ROOT, 'master'),
  ];

  for (const repo of manifest.repos) {
    rows.push(getRepoStatusRow(repo.path, path.join(ROOT, repo.path), repo.branch));
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

async function cmdSync(args) {
  const { doReset, doPull, jobs, changedFile, targets } = parseSyncArgs(args);
  const repos = selectRepos(targets);

  const results = await mapPool(repos, jobs, async (repo) => {
    const dir = path.join(ROOT, repo.path);
    const hasGit = fs.existsSync(path.join(dir, '.git'));

    try {
      if (!fs.existsSync(dir) || (!hasGit && fs.readdirSync(dir).length === 0)) {
        fs.mkdirSync(path.dirname(dir), { recursive: true });
        if (fs.existsSync(dir)) fs.rmdirSync(dir);
        await cloneAsync(repo.url, repo.branch, dir);
        const head = await gitAsync(dir, ['rev-parse', '--short', 'HEAD'], { allowFail: true }) || '';
        return { path: repo.path, changed: true, ok: true, line: `[clone]  ${repo.path} (${head})` };
      }

      if (!hasGit) {
        return {
          path: repo.path,
          changed: false,
          ok: false,
          line: `[error]  ${repo.path} exists and is not empty, but has no .git directory`,
        };
      }

      if (!doPull) {
        return { path: repo.path, changed: false, ok: true, line: `[ok]     ${repo.path}` };
      }

      const beforeHead = await gitAsync(dir, ['rev-parse', '--short', 'HEAD'], { allowFail: true }) || '';

      if (doReset) {
        await gitAsync(dir, ['fetch', 'origin', '--prune']);
        await gitAsync(dir, ['checkout', '-B', repo.branch, `origin/${repo.branch}`]);
        await gitAsync(dir, ['reset', '--hard', `origin/${repo.branch}`]);
        await gitAsync(dir, ['remote', 'set-head', 'origin', '-a'], { allowFail: true });
        const afterHead = await gitAsync(dir, ['rev-parse', '--short', 'HEAD'], { allowFail: true }) || '';
        if (beforeHead !== afterHead) {
          return { path: repo.path, changed: true, ok: true, line: `[reset]  ${repo.path} (${beforeHead} -> ${afterHead})` };
        }
        return { path: repo.path, changed: false, ok: true, line: `[latest] ${repo.path} (${afterHead})` };
      }

      const branch = await gitAsync(dir, ['branch', '--show-current'], { allowFail: true });
      const dirty = Boolean(await gitAsync(dir, ['status', '--porcelain'], { allowFail: true }));
      if (dirty) {
        return { path: repo.path, changed: false, ok: true, line: `[skip]   ${repo.path} (working tree dirty)` };
      }
      if (branch !== repo.branch) {
        return {
          path: repo.path,
          changed: false,
          ok: true,
          line: `[skip]   ${repo.path} (on branch ${branch || 'detached'}, expected ${repo.branch})`,
        };
      }

      await gitAsync(dir, ['fetch', 'origin', '--prune']);
      await gitAsync(dir, ['merge', '--ff-only', `origin/${repo.branch}`]);
      const afterHead = await gitAsync(dir, ['rev-parse', '--short', 'HEAD'], { allowFail: true }) || '';
      if (beforeHead !== afterHead) {
        return { path: repo.path, changed: true, ok: true, line: `[update] ${repo.path} (${beforeHead} -> ${afterHead})` };
      }
      return { path: repo.path, changed: false, ok: true, line: `[latest] ${repo.path} (${afterHead})` };
    } catch (err) {
      return { path: repo.path, changed: false, ok: false, line: `[fail]   ${repo.path}: ${err.message}` };
    }
  });

  const changedPaths = [];
  let failures = 0;
  for (const res of results) {
    if (res.ok) {
      console.log(res.line);
    } else {
      console.error(res.line);
      failures += 1;
    }
    if (res.changed) changedPaths.push(res.path);
  }

  if (changedFile) {
    fs.writeFileSync(changedFile, `${changedPaths.join('\n')}${changedPaths.length ? '\n' : ''}`);
  }

  if (failures > 0) {
    console.error(`Sync finished with ${failures} failure(s).`);
    process.exit(1);
  }
}

function cmdPrune(args) {
  const dryRun = args.includes('--dry-run');
  const targets = [
    { path: '.', branch: 'master' },
    ...manifest.repos.map((r) => ({ path: r.path, branch: r.branch })),
  ];

  let totalDeleted = 0;
  for (const target of targets) {
    const dir = target.path === '.' ? ROOT : path.join(ROOT, target.path);
    if (!fs.existsSync(path.join(dir, '.git'))) continue;

    const mergedRaw = git(dir, ['branch', '--merged', target.branch, '--format=%(refname:short)'], { allowFail: true }) || '';
    const current = git(dir, ['branch', '--show-current'], { allowFail: true }) || '';
    const candidates = mergedRaw
      .split('\n')
      .map((b) => b.trim())
      .filter((b) => b && b !== target.branch && b !== current);

    for (const branch of candidates) {
      if (dryRun) {
        console.log(`[dry-run] delete merged branch ${target.path}: ${branch}`);
      } else {
        git(dir, ['branch', '-d', branch]);
        console.log(`[prune]   ${target.path}: deleted ${branch}`);
      }
      totalDeleted += 1;
    }
  }

  if (totalDeleted === 0) {
    console.log('No merged local branches to prune.');
  } else {
    console.log(`${dryRun ? 'Would delete' : 'Deleted'} ${totalDeleted} merged local branch(es).`);
  }
}

async function cmdCheck(args = []) {
  const targetQueries = args.filter((a) => !a.startsWith('-'));
  const scoped = targetQueries.length > 0 && !targetQueries.some((q) => q.toLowerCase() === 'all');
  const reposToCheck = selectRepos(targetQueries);
  const checkedPaths = new Set(reposToCheck.map((r) => r.path));

  const errors = [];
  const warnings = [];
  const fail = (msg) => errors.push(msg);
  const warn = (msg) => warnings.push(msg);

  // 0. Validate manifest integrity & workspace scripts syntax
  const seenNames = new Set();
  const seenPaths = new Set();
  for (const repo of manifest.repos) {
    if (!repo.name || !repo.path || !repo.branch || !repo.url) {
      fail(`repos.json: incomplete entry ${JSON.stringify(repo)}`);
      continue;
    }
    if (seenNames.has(repo.name)) fail(`repos.json: duplicate repo name "${repo.name}"`);
    if (seenPaths.has(repo.path)) fail(`repos.json: duplicate repo path "${repo.path}"`);
    seenNames.add(repo.name);
    seenPaths.add(repo.path);
  }

  try {
    execFileSync(process.execPath, ['--check', path.join(ROOT, 'scripts/ws.mjs')], { stdio: 'pipe' });
  } catch (err) {
    fail(`scripts/ws.mjs syntax error: ${err.stderr?.toString().trim()}`);
  }
  if (fs.existsSync(path.join(ROOT, 'scripts/build.sh'))) {
    try {
      execFileSync('sh', ['-n', path.join(ROOT, 'scripts/build.sh')], { stdio: 'pipe' });
    } catch (err) {
      fail(`scripts/build.sh syntax error: ${err.stderr?.toString().trim()}`);
    }
  }

  // 1. Check presence, branch, & origin remotes for selected repos
  for (const repo of reposToCheck) {
    const dir = path.join(ROOT, repo.path);
    if (!fs.existsSync(dir)) {
      fail(`Missing repo checkout: ${repo.path}`);
      continue;
    }
    const origin = git(dir, ['remote', 'get-url', 'origin'], { allowFail: true });
    if (normalizeUrl(origin) !== normalizeUrl(repo.url)) {
      fail(`${repo.path}: origin "${origin}" does not match manifest "${repo.url}"`);
    }
    const branch = git(dir, ['branch', '--show-current'], { allowFail: true });
    if (branch && branch !== repo.branch) {
      warn(`${repo.path}: currently on branch "${branch}" (manifest default is "${repo.branch}")`);
    }
  }

  // 2. Load index README and current-state doc for cross-checking (when present)
  const indexReadmePath = path.join(ROOT, 'index/utools-plugins/README.md');
  const indexReadme = fs.existsSync(indexReadmePath) ? fs.readFileSync(indexReadmePath, 'utf8') : '';
  const stateDocPath = path.join(ROOT, 'skills/utools-plugin-development/references/current-state.md');
  const stateDoc = fs.existsSync(stateDocPath) ? fs.readFileSync(stateDocPath, 'utf8') : '';

  const stateHeights = new Map();
  for (const line of stateDoc.split('\n')) {
    const match = line.match(/^\|\s*(Fun[A-Za-z]+)\s*\|[^|]+\|\s*(\d+)\s*\|/);
    if (match) {
      stateHeights.set(match[1].toLowerCase(), Number(match[2]));
    }
  }

  // 3. Check selected plugins
  const plugins = reposToCheck.filter((r) => r.category === 'plugin');
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
    const npmLockPath = path.join(dir, 'package-lock.json');
    if (fs.existsSync(npmLockPath)) {
      const lock = readJson(npmLockPath);
      if (lock.version !== pkg.version || lock.packages?.['']?.version !== pkg.version) {
        fail(`${repo.path}: package-lock.json version mismatch (expected ${pkg.version})`);
      }
    }
    if (!pkg.name?.startsWith('@farfarfun/utools-')) {
      fail(`${repo.path}: package.json#name should use @farfarfun/utools-* scope (got "${pkg.name}")`);
    }
    if (pkg.funbuild?.build !== 'sh build.sh') {
      fail(`${repo.path}: package.json#funbuild.build should be "sh build.sh" (got ${JSON.stringify(pkg.funbuild?.build)})`);
    }
    if (plugin.main !== 'dist/index.html') {
      fail(`${repo.path}: plugin.json#main should be "dist/index.html" (got "${plugin.main}")`);
    }
    if (!Array.isArray(plugin.features) || plugin.features.length === 0) {
      fail(`${repo.path}: plugin.json#features must be a non-empty array`);
    }

    const utoolsDir = path.join(dir, 'utools');
    for (const rel of [plugin.logo, plugin.preload].filter(Boolean)) {
      if (!fs.existsSync(path.join(utoolsDir, rel))) {
        fail(`${repo.path}: missing referenced utools/${rel}`);
      }
    }
    const logoPath = path.join(utoolsDir, plugin.logo || '');
    if (plugin.logo && fs.existsSync(logoPath) && plugin.logo.endsWith('.png')) {
      const buf = fs.readFileSync(logoPath);
      if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG' || buf.readUInt32BE(16) !== 256 || buf.readUInt32BE(20) !== 256) {
        fail(`${repo.path}: utools/${plugin.logo} must be a 256x256 PNG`);
      }
    }
    if (fs.existsSync(path.join(utoolsDir, 'logo.svg')) && plugin.logo !== 'logo.svg') {
      fail(`${repo.path}: unreferenced utools/logo.svg should not stay in utools/ packaging directory`);
    }
    for (const feat of plugin.features || []) {
      if (feat.icon && !fs.existsSync(path.join(utoolsDir, feat.icon))) {
        fail(`${repo.path}: missing feature icon utools/${feat.icon}`);
      }
    }

    for (const required of ['build.sh', 'identity.json', '.github/workflows/ci.yml', '.github/workflows/release.yml']) {
      if (!fs.existsSync(path.join(dir, required))) {
        fail(`${repo.path}: missing ${required}`);
      }
    }
    const identityPath = path.join(dir, 'identity.json');
    if (fs.existsSync(identityPath)) {
      const identity = readJson(identityPath);
      if (!identity.pluginId) warn(`${repo.path}: identity.json pluginId is empty (register on uTools before release)`);
      for (const secretKey of ['mid', 'uid', 'cellphone']) {
        if (secretKey in identity) fail(`${repo.path}: identity.json must not contain private field "${secretKey}"`);
      }
    }
    if (fs.existsSync(path.join(dir, 'utools/build.sh'))) {
      fail(`${repo.path}: utools/build.sh should not exist (keep single build.sh at repo root)`);
    }

    if (indexReadme && !indexReadme.includes(repo.name)) {
      fail(`index/utools-plugins/README.md does not list ${repo.name}`);
    }
    if (indexReadme && plugin.pluginName && !indexReadme.includes(plugin.pluginName)) {
      fail(`index/utools-plugins/README.md does not list display name "${plugin.pluginName}" for ${repo.name}`);
    }

    const shortKey = repo.name.replace(/^utools-/, '').toLowerCase();
    const docHeight = stateHeights.get(shortKey);
    const actualHeight = plugin.pluginSetting?.height;
    if (docHeight !== undefined && actualHeight !== undefined && docHeight !== actualHeight) {
      fail(`skills/.../current-state.md height mismatch for ${repo.name}: doc=${docHeight}, plugin.json=${actualHeight}`);
    }
  }

  // 4. Check apps/utools-mobile shared code parity & build.sh (only when full check or mobile selected)
  const mobileDir = path.join(ROOT, 'apps/utools-mobile');
  if ((!scoped || checkedPaths.has('apps/utools-mobile')) && fs.existsSync(mobileDir)) {
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
          if (!srcText.startsWith(dstText)) {
            fail('apps/utools-mobile: src/shared/link/types.ts diverged from prefix of plugins/utools-funlink/src/lib/types.ts');
          }
        } else if (srcText !== dstText) {
          fail(`apps/utools-mobile: src/shared/link/${file} drifted from plugins/utools-funlink/src/lib/${file}`);
        }
      }
    }
  }

  // 5. Check tools/utools-shots syntax & plugin root resolution (only when full check or shots selected)
  const shotsDir = path.join(ROOT, 'tools/utools-shots');
  if ((!scoped || checkedPaths.has('tools/utools-shots')) && fs.existsSync(shotsDir)) {
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
    console.log(`OK: checked ${reposToCheck.length} repo(s) (${plugins.length} plugin(s)), 0 errors, ${warnings.length} warnings.`);
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
  case 'init':
  case 'sync':
    await cmdSync(rest);
    break;
  case 'prune':
    cmdPrune(rest);
    break;
  case 'check':
    await cmdCheck(rest);
    break;
  default:
    console.error('Usage: node scripts/ws.mjs <status|init|sync [--pull|--reset] [--jobs N] [repo...]|prune [--dry-run]|check [repo...]>');
    process.exit(2);
}
