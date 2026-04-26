#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2];
if (!root) {
  console.error('Usage: patch-umbrel.js <repo-root>');
  process.exit(1);
}

function patchFile(relPath, transform) {
  const file = path.join(root, relPath);
  if (!fs.existsSync(file)) return false;
  const before = fs.readFileSync(file, 'utf8');
  const after = transform(before);
  if (after !== before) {
    fs.writeFileSync(file, after);
    console.log(`patched: ${relPath}`);
    return true;
  }
  return false;
}

function insertAfter(text, needle, insert) {
  if (!text.includes(needle)) return text;
  if (text.includes(insert.trim())) return text;
  return text.replace(needle, `${needle}${insert}`);
}

function insertAfterImportBlock(text, insert) {
  if (text.includes(insert.trim())) return text;
  const lines = text.split('\n');
  let lastImport = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^\s*import\b/.test(line)) {
      lastImport = i;
      continue;
    }
    if (/^\s*$/.test(line) && lastImport !== -1) {
      continue;
    }
    break;
  }
  if (lastImport === -1) return `${insert}\n${text}`;
  lines.splice(lastImport + 1, 0, '', insert.trim(), '');
  return lines.join('\n');
}

function patchIsUmbrelHome() {
  patchFile('packages/umbreld/source/modules/is-umbrel-home.ts', (text) => {
    const marker = "if (process.env.UMBREL_DOCKER_MODE === 'true') return false";
    if (text.includes(marker)) return text;
    return text.replace(
      'export default async function isUmbrelHome() {\n',
      "export default async function isUmbrelHome() {\n\tif (process.env.UMBREL_DOCKER_MODE === 'true') return false\n\n",
    );
  });
}

function patchAppsTs() {
  patchFile('packages/umbreld/source/modules/apps/apps.ts', (text) => {
    const constLine = "const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'";
    if (!text.includes(constLine)) {
      text = insertAfterImportBlock(text, constLine);
    }

    const guard = [
      '\t\tif (UMBREL_DOCKER_MODE) {',
      "\t\t\tthis.logger.log('Skipping Docker state cleanup in docker mode')",
      '\t\t\treturn',
      '\t\t}\n',
    ].join('\n');

    if (!text.includes('Skipping Docker state cleanup in docker mode')) {
      text = text.replace('async cleanDockerState() {\n', `async cleanDockerState() {\n${guard}`);
    }
    return text;
  });
}

function patchAppEnvironment() {
  patchFile('packages/umbreld/source/modules/apps/legacy-compat/app-environment.ts', (text) => {
    text = insertAfter(text, "import {$} from 'execa'\n", "import fse from 'fs-extra'\n");
    text = insertAfter(
      text,
      "\tif (process.env.TEST === 'true') inheritStdio = false\n",
      "\tconst dockerMode = process.env.UMBREL_DOCKER_MODE === 'true'\n",
    );
    text = insertAfter(
      text,
      "\tconst composePath = join(currentDirname, 'docker-compose.yml')\n",
      "\tconst composeProjectName = dockerMode ? 'umbrelc' : 'umbrel'\n",
    );
    text = insertAfter(
      text,
      "\tconst torEnabled = await umbreld.store.get('torEnabled')\n",
      '\tconst torDirectory = `${umbreld.dataDirectory}/tor`\n' +
        '\tconst torProxyTorrc = `${torDirectory}/tor-proxy-torrc`\n' +
        '\tconst torServerTorrc = `${torDirectory}/tor-server-torrc`\n',
    );

    text = text.replace(
      /\t\t\tUMBREL_TORRC: torEnabled \? `\$\{currentDirname\}\/tor-server-torrc` : `\$\{currentDirname\}\/tor-proxy-torrc`,\n/,
      '\t\t\tUMBREL_TORRC: torEnabled\n' +
        '\t\t\t\t? dockerMode\n' +
        '\t\t\t\t\t? torServerTorrc\n' +
        '\t\t\t\t\t: `${currentDirname}/tor-server-torrc`\n' +
        '\t\t\t\t: dockerMode\n' +
        '\t\t\t\t\t? torProxyTorrc\n' +
        '\t\t\t\t\t: `${currentDirname}/tor-proxy-torrc`,\n',
    );

    if (!text.includes('In docker mode, app containers run on the host Docker daemon')) {
      text = text.replace(
        "\tif (command === 'up') {\n",
        "\tif (command === 'up') {\n" +
          '\t\t// In docker mode, app containers run on the host Docker daemon and can only mount host paths.\n' +
          '\t\tif (dockerMode) {\n' +
          '\t\t\tawait fse.ensureDir(torDirectory)\n' +
          '\t\t\tawait fse.copy(`${currentDirname}/tor-proxy-torrc`, torProxyTorrc)\n' +
          '\t\t\tawait fse.copy(`${currentDirname}/tor-server-torrc`, torServerTorrc)\n' +
          '\t\t}\n\n',
      );
    }

    text = text.replace(
      /docker compose --project-name umbrel --file \$\{composePath\}/g,
      'docker compose --project-name ${composeProjectName} --file ${composePath}',
    );

    // Fallback for older source variants where the anchors above are missing.
    if (text.includes('dockerMode') && !text.includes("const dockerMode = process.env.UMBREL_DOCKER_MODE === 'true'")) {
      const insertDockerMode = "$1\tconst dockerMode = process.env.UMBREL_DOCKER_MODE === 'true'\n";
      let next = text.replace(
        /(export default async function appEnvironment\([^\n]*\) {\n)/,
        insertDockerMode,
      );
      if (next === text) {
        next = text.replace(
          /(export async function appEnvironment\([^\n]*\) {\n)/,
          insertDockerMode,
        );
      }
      if (next === text) {
        next = text.replace(
          /(^\s*async function appEnvironment\([^\n]*\) {\n)/m,
          insertDockerMode,
        );
      }
      text = next;
    }

    if (text.includes('composeProjectName') && !text.includes('const composeProjectName =')) {
      text = text.replace(
        /(\tconst composePath = [^\n]*\n)/,
        "$1\tconst composeProjectName = dockerMode ? 'umbrelc' : 'umbrel'\n",
      );
    }

    // Last fallback: if dockerMode is used but function-local insertion failed, define it globally.
    if (text.includes('dockerMode') && !text.includes("const dockerMode = process.env.UMBREL_DOCKER_MODE === 'true'")) {
      text = insertAfterImportBlock(text, "const dockerMode = process.env.UMBREL_DOCKER_MODE === 'true'");
    }

    return text;
  });
}

function patchAppScriptTs() {
  patchFile('packages/umbreld/source/modules/apps/legacy-compat/app-script.ts', (text) => {
    if (text.includes('UMBREL_DOCKER_MODE: process.env.UMBREL_DOCKER_MODE ?? \'false\'')) return text;
    return text.replace(
      '\t\t\tSCRIPT_DOCKER_FRAGMENTS: currentDirname,\n',
      '\t\t\tSCRIPT_DOCKER_FRAGMENTS: currentDirname,\n' +
        "\t\t\tUMBREL_DOCKER_MODE: process.env.UMBREL_DOCKER_MODE ?? 'false',\n",
    );
  });
}

function patchLegacyAppScript() {
  patchFile('packages/umbreld/source/modules/apps/legacy-compat/app-script', (text) => {
    if (!text.includes('UMBREL_DOCKER_MODE:-false')) {
      text = text.replace(
        '  export TOR_DATA_DIR="${UMBREL_ROOT}/tor/data"\n' +
          '  export TOR_ENTRYPOINT_SCRIPT="${SCRIPT_DOCKER_FRAGMENTS}/tor-entrypoint.sh"\n',
        '  export TOR_DATA_DIR="${UMBREL_ROOT}/tor/data"\n' +
          '  if [[ "${UMBREL_DOCKER_MODE:-false}" == "true" ]]; then\n' +
          '    export TOR_ENTRYPOINT_SCRIPT="${UMBREL_ROOT}/tor/tor-entrypoint.sh"\n' +
          '  else\n' +
          '    export TOR_ENTRYPOINT_SCRIPT="${SCRIPT_DOCKER_FRAGMENTS}/tor-entrypoint.sh"\n' +
          '  fi\n',
      );

      text = text.replace(
        '  if [[ "${REMOTE_TOR_ACCESS}" == "true" ]]; then\n' +
          '    compose_files+=( "--file" "${tor_compose_file}" )\n' +
          '  fi\n',
        '  if [[ "${REMOTE_TOR_ACCESS}" == "true" ]]; then\n' +
          '    if [[ "${UMBREL_DOCKER_MODE:-false}" == "true" ]]; then\n' +
          '      mkdir -p "$(dirname "${TOR_ENTRYPOINT_SCRIPT}")"\n' +
          '      cp "${SCRIPT_DOCKER_FRAGMENTS}/tor-entrypoint.sh" "${TOR_ENTRYPOINT_SCRIPT}"\n' +
          '      chmod +x "${TOR_ENTRYPOINT_SCRIPT}"\n' +
          '    fi\n' +
          '    compose_files+=( "--file" "${tor_compose_file}" )\n' +
          '  fi\n',
      );
    }
    return text;
  });
}

function patchUpdateModules() {
  const files = [
    'packages/umbreld/source/modules/update.ts',
    'packages/umbreld/source/modules/system/update.ts',
  ];

  const dockerReleaseHelpers =
    "function normalizeReleaseVersion(value: string): string | null {\n" +
    "\tconst normalised = value.replace(/^v/, '')\n" +
    "\tif (!/^\\d+\\.\\d+\\.\\d+(?:[-.][0-9A-Za-z.-]+)?$/.test(normalised)) return null\n" +
    "\treturn normalised\n" +
    "}\n\n" +
    "function parseReleaseVersionParts(value: string): {major: number; minor: number; patch: number; prerelease: string | null} | null {\n" +
    "\tconst normalised = normalizeReleaseVersion(value)\n" +
    "\tif (!normalised) return null\n" +
    "\tconst match = normalised.match(/^(\\d+)\\.(\\d+)\\.(\\d+)(?:[-.]([0-9A-Za-z.-]+))?$/)\n" +
    "\tif (!match) return null\n" +
    "\treturn {\n" +
    "\t\tmajor: Number(match[1]),\n" +
    "\t\tminor: Number(match[2]),\n" +
    "\t\tpatch: Number(match[3]),\n" +
    "\t\tprerelease: match[4] ?? null,\n" +
    "\t}\n" +
    "}\n\n" +
    "function compareReleaseVersions(a: string, b: string) {\n" +
    "\tconst aParts = parseReleaseVersionParts(a)\n" +
    "\tconst bParts = parseReleaseVersionParts(b)\n" +
    "\tif (!aParts && !bParts) return a.localeCompare(b)\n" +
    "\tif (!aParts) return -1\n" +
    "\tif (!bParts) return 1\n" +
    "\tif (aParts.major !== bParts.major) return aParts.major - bParts.major\n" +
    "\tif (aParts.minor !== bParts.minor) return aParts.minor - bParts.minor\n" +
    "\tif (aParts.patch !== bParts.patch) return aParts.patch - bParts.patch\n" +
    "\tif (aParts.prerelease === null && bParts.prerelease === null) return 0\n" +
    "\tif (aParts.prerelease === null) return 1\n" +
    "\tif (bParts.prerelease === null) return -1\n" +
    "\tconst aTokens = aParts.prerelease.split(/[.-]/)\n" +
    "\tconst bTokens = bParts.prerelease.split(/[.-]/)\n" +
    "\tconst length = Math.max(aTokens.length, bTokens.length)\n" +
    "\tfor (let i = 0; i < length; i++) {\n" +
    "\t\tconst aToken = aTokens[i]\n" +
    "\t\tconst bToken = bTokens[i]\n" +
    "\t\tif (aToken === undefined) return -1\n" +
    "\t\tif (bToken === undefined) return 1\n" +
    "\t\tif (aToken === bToken) continue\n" +
    "\t\tconst aNumeric = /^\\d+$/.test(aToken)\n" +
    "\t\tconst bNumeric = /^\\d+$/.test(bToken)\n" +
    "\t\tif (aNumeric && bNumeric) return Number(aToken) - Number(bToken)\n" +
    "\t\tif (aNumeric) return -1\n" +
    "\t\tif (bNumeric) return 1\n" +
    "\t\treturn aToken.localeCompare(bToken)\n" +
    "\t}\n" +
    "\treturn 0\n" +
    "}\n\n" +
    "function getDockerUpdateStatePath() {\n" +
    "\tconst dataDirectory = process.env.UMBREL_DATA_DIR\n" +
    "\tif (!dataDirectory) return null\n" +
    "\treturn `${dataDirectory}/.umbrel-docker/update-state.json`\n" +
    "}\n\n" +
    "function resolveDockerUpdateStatus() {\n" +
    "\tif (process.env.UMBREL_DOCKER_MODE !== 'true') return null\n" +
    "\tconst statePath = getDockerUpdateStatePath()\n" +
    "\tif (!statePath || !fse.existsSync(statePath)) return null\n" +
    "\ttry {\n" +
    "\t\tconst state = fse.readJsonSync(statePath) as Partial<UpdateStatus> & {error?: unknown}\n" +
    "\t\tconst next: UpdateStatus = {...updateStatus}\n" +
    "\t\tif (typeof state.running === 'boolean') next.running = state.running\n" +
    "\t\tif (typeof state.progress === 'number' && Number.isFinite(state.progress)) {\n" +
    "\t\t\tnext.progress = Math.max(0, Math.min(100, Math.floor(state.progress)))\n" +
    "\t\t}\n" +
    "\t\tif (typeof state.description === 'string') next.description = state.description\n" +
    "\t\tif (typeof state.error === 'string') next.error = state.error\n" +
    "\t\tif (state.error === false) next.error = false\n" +
    "\t\tif (state.error === true) next.error = 'Update failed'\n" +
    "\t\treturn next\n" +
    "\t} catch (error) {\n" +
    "\t\treturn null\n" +
    "\t}\n" +
    "}\n\n" +
    "async function resolveLatestDockerRelease(channel: string) {\n" +
    "\tif (channel !== 'beta') return null\n" +
    "\tconst refsUrl = 'https://github.com/getumbrel/umbrel.git/info/refs?service=git-upload-pack'\n" +
    "\tconst result = await fetch(refsUrl, {\n" +
    "\t\theaders: {Accept: '*/*', 'User-Agent': 'umbrel-docker'},\n" +
    "\t})\n" +
    "\tif (!result.ok) return null\n" +
    "\tconst body = await result.text()\n" +
    "\tconst versions = new Set<string>()\n" +
    "\tfor (const match of body.matchAll(/[0-9a-f]{40}\\srefs\\/tags\\/([^\\0\\n\\r]+)/g)) {\n" +
    "\t\tconst version = normalizeReleaseVersion(match[1])\n" +
    "\t\tif (!version) continue\n" +
    "\t\tversions.add(version)\n" +
    "\t}\n" +
    "\tconst sortedVersions = [...versions].sort(compareReleaseVersions)\n" +
    "\tconst latest = sortedVersions[sortedVersions.length - 1]\n" +
    "\tif (!latest) return null\n" +
    "\treturn {\n" +
    "\t\tversion: latest,\n" +
    "\t\tname: `umbrelOS ${latest}`,\n" +
    "\t\treleaseNotes: `Docker mode: use the host update agent (\\'umbrelctl agent\\') or run 'bash ./umbrelctl update --ref ${latest}'.`,\n" +
    "\t\tupdateScript: `https://raw.githubusercontent.com/getumbrel/umbrel/${latest}/scripts/update-script`,\n" +
    "\t}\n" +
    "}\n";

  const dockerReleaseBranch =
    "\tif (process.env.UMBREL_DOCKER_MODE === 'true') {\n" +
    "\t\ttry {\n" +
    "\t\t\tconst release = await resolveLatestDockerRelease(channel)\n" +
    "\t\t\tif (release) return release\n" +
    "\t\t} catch (error) {\n" +
    "\t\t\tumbreld.logger.error('Failed to resolve latest docker release', error)\n" +
    "\t\t}\n" +
    "\t}\n\n";

  const releaseChannelFallback =
    "\tlet channel = process.env.UMBREL_RELEASE_CHANNEL === 'beta' ? 'beta' : 'stable'\n" +
    "\ttry {\n" +
    "\t\tconst storedChannel = await umbreld.store.get('settings.releaseChannel')\n" +
    "\t\tif (storedChannel === 'beta' || storedChannel === 'stable') channel = storedChannel\n" +
    "\t} catch (error) {\n" +
    "\t\tumbreld.logger.error(`Failed to get release channel`, error)\n" +
    "\t}\n";

  const dockerGuardMarker = 'Docker mode update request queued for host agent';
  const dockerGuard =
    "\tif (process.env.UMBREL_DOCKER_MODE === 'true') {\n" +
    "\t\tlet targetVersion = '<version>'\n" +
    "\t\tlet targetChannel = process.env.UMBREL_RELEASE_CHANNEL === 'beta' ? 'beta' : 'stable'\n" +
    "\t\ttry {\n" +
    "\t\t\tconst latestRelease = await getLatestRelease(umbreld)\n" +
    "\t\t\tif (latestRelease?.version) targetVersion = latestRelease.version.replace('v', '')\n" +
    "\t\t} catch (error) {\n" +
    "\t\t\tumbreld.logger.error('Failed to resolve latest release in docker mode', error)\n" +
    "\t\t}\n" +
    "\t\ttry {\n" +
    "\t\t\tconst storedChannel = await umbreld.store.get('settings.releaseChannel')\n" +
    "\t\t\tif (storedChannel === 'beta' || storedChannel === 'stable') targetChannel = storedChannel\n" +
    "\t\t} catch (error) {\n" +
    "\t\t\tumbreld.logger.error('Failed to resolve release channel in docker mode', error)\n" +
    "\t\t}\n" +
    "\t\tconst updateCommand =\n" +
    "\t\t\ttargetVersion === '<version>'\n" +
    "\t\t\t\t? 'bash ./umbrelctl update --ref <version>'\n" +
    "\t\t\t\t: `bash ./umbrelctl update --ref ${targetVersion}`\n" +
    "\t\tconst requestDirectory = `${umbreld.dataDirectory}/.umbrel-docker`\n" +
    "\t\tconst requestFile = `${requestDirectory}/update-request.json`\n" +
    "\t\tconst requestPayload = {\n" +
    "\t\t\tversion: targetVersion,\n" +
    "\t\t\tchannel: targetChannel,\n" +
    "\t\t\trequestedAt: new Date().toISOString(),\n" +
    "\t\t\tsource: 'umbrelos-ui',\n" +
    "\t\t}\n" +
    "\t\ttry {\n" +
    "\t\t\tawait fse.ensureDir(requestDirectory)\n" +
    "\t\t\tawait fse.writeJson(requestFile, requestPayload, {spaces: 2})\n" +
    "\t\t\tsetUpdateStatus({\n" +
    "\t\t\t\trunning: true,\n" +
    "\t\t\t\tprogress: 5,\n" +
    "\t\t\t\tdescription: `Docker mode update request queued for host agent (${targetVersion})`,\n" +
    "\t\t\t\terror: false,\n" +
    "\t\t\t})\n" +
    "\t\t\treturn true\n" +
    "\t\t} catch (error) {\n" +
    "\t\t\tumbreld.logger.error('Failed to queue docker mode update request', error)\n" +
    "\t\t\tsetUpdateStatus({\n" +
    "\t\t\t\trunning: false,\n" +
    "\t\t\t\tprogress: 0,\n" +
    "\t\t\t\tdescription: 'Failed to queue docker mode update request',\n" +
    "\t\t\t\terror: `Docker mode: run '${updateCommand}' on the host machine`,\n" +
    "\t\t\t})\n" +
    "\t\t\treturn false\n" +
    "\t\t}\n" +
    "\t}\n\n";

  const legacyGuardPattern =
    /\tif \(process\.env\.UMBREL_DOCKER_MODE === 'true'\) \{\n\t\tsetUpdateStatus\(\{error: 'Updates not supported, update the container instead!'\}\)\n\t\treturn false\n\t\}\n\n/;

  for (const relPath of files) {
    patchFile(relPath, (text) => {
      if (!text.includes('export async function performUpdate')) return text;

      text = insertAfter(text, "import {$} from 'execa'\n", "import fse from 'fs-extra'\n");

      if (!text.includes('function compareReleaseVersions(a: string, b: string)')) {
        text = text.replace(
          /export function getUpdateStatus\(\) {\n\treturn updateStatus\n}\n/,
          (match) => `${match}\n${dockerReleaseHelpers}\n`,
        );
      }

      if (!text.includes('const dockerStatus = resolveDockerUpdateStatus()')) {
        text = text.replace(
          /export function getUpdateStatus\(\) {\n[\s\S]*?\n}\n/,
          "export function getUpdateStatus() {\n\tconst dockerStatus = resolveDockerUpdateStatus()\n\tif (dockerStatus) return dockerStatus\n\treturn updateStatus\n}\n",
        );
      }

      if (!text.includes('resolveLatestDockerRelease(channel)')) {
        text = text.replace(
          "\tconst updateUrl = new URL('https://api.umbrel.com/latest-release')\n",
          `${dockerReleaseBranch}\tconst updateUrl = new URL('https://api.umbrel.com/latest-release')\n`,
        );
      }

      if (!text.includes("process.env.UMBREL_RELEASE_CHANNEL === 'beta'")) {
        text = text.replace(
          /[\t ]*let channel = 'stable'\n[\t ]*try \{\n[\t ]*channel = \(await umbreld\.store\.get\('settings\.releaseChannel'\)\) \|\| 'stable'\n[\t ]*\} catch \(error\) \{\n[\t ]*umbreld\.logger\.error\(`Failed to get release channel`, error\)\n[\t ]*\}\n/,
          releaseChannelFallback,
        );
      }

      if (legacyGuardPattern.test(text)) {
        text = text.replace(legacyGuardPattern, dockerGuard);
      }

      if (text.includes(dockerGuardMarker)) return text;

      return text.replace(
        /export async function performUpdate\(umbreld: Umbreld\) {\n/,
        `export async function performUpdate(umbreld: Umbreld) {\n${dockerGuard}`,
      );
    });
  }
}

function patchSystemRoutes() {
  const files = [
    'packages/umbreld/source/modules/system/routes.ts',
    'packages/umbreld/source/modules/system.ts',
  ];

  for (const relPath of files) {
    patchFile(relPath, (text) => {
      if (!text.includes('getReleaseChannel')) return text;

      if (!text.includes("const storedChannel = await ctx.umbreld.store.get('settings.releaseChannel')")) {
        text = text.replace(
          /return \(await ctx\.umbreld\.store\.get\('settings\.releaseChannel'\)\) \|\| 'stable'/,
          "const storedChannel = await ctx.umbreld.store.get('settings.releaseChannel')\n\t\tif (storedChannel === 'beta' || storedChannel === 'stable') return storedChannel\n\t\treturn process.env.UMBREL_RELEASE_CHANNEL === 'beta' ? 'beta' : 'stable'",
        );
      }

      if (!text.includes("if (process.env.UMBREL_DOCKER_MODE !== 'true')")) {
        text = text.replace(
          /if \(success\) {\n\s*await setTimeout\(1000\)\n\s*await ctx\.umbreld\.stop\(\)\n\s*await reboot\(\)\n\s*}/,
          "if (success) {\n\t\t\t\tif (process.env.UMBREL_DOCKER_MODE !== 'true') {\n\t\t\t\t\tawait setTimeout(1000)\n\t\t\t\t\tawait ctx.umbreld.stop()\n\t\t\t\t\tawait reboot()\n\t\t\t\t} else {\n\t\t\t\t\tsystemStatus = 'running'\n\t\t\t\t}\n\t\t\t}",
        );
      }

      return text;
    });
  }
}

function patchComposeNetwork() {
  patchFile('packages/umbreld/source/modules/apps/legacy-compat/docker-compose.yml', (text) => {
    if (text.includes('external: true')) return text;
    if (!text.includes('name: umbrel_main_network')) return text;

    const oldBlock =
      "networks:\n" +
      "  default:\n" +
      "    name: umbrel_main_network\n" +
      "    ipam:\n" +
      "      driver: default\n" +
      "      config:\n" +
      "        - subnet: '$NETWORK_IP/16'\n";
    const newBlock = "networks:\n  default:\n    name: umbrel_main_network\n    external: true\n";

    if (text.includes(oldBlock)) return text.replace(oldBlock, newBlock);

    // Fallback for minor formatting differences
    return text.replace(
      /networks:\n  default:\n    name: umbrel_main_network\n(?:    ipam:\n(?:      .*\n)*)?/,
      newBlock,
    );
  });
}

function patchCommitPartition() {
  const files = [
    'packages/umbreld/source/modules/system.ts',
    'packages/umbreld/source/modules/system/system.ts',
  ];

  for (const relPath of files) {
    patchFile(relPath, (text) => {
      if (!text.includes('export async function commitOsPartition')) return text;
      if (text.includes('Skipping OS partition commit in docker mode')) return text;

      return text.replace(
        'export async function commitOsPartition(umbreld: Umbreld): Promise<boolean> {\n',
        "export async function commitOsPartition(umbreld: Umbreld): Promise<boolean> {\n\tif (process.env.UMBREL_DOCKER_MODE === 'true') {\n\t\tumbreld.logger.log('Skipping OS partition commit in docker mode')\n\t\treturn true\n\t}\n\n",
      );
    });
  }
}

function patchFilesPathValidation() {
  patchFile('packages/umbreld/source/modules/files/files.ts', (text) => {
    if (!text.includes("if (!realPath.startsWith(basePath)) throw new Error(`[escapes-base] '${virtualPath}' escapes '${basePath}'`)")) {
      return text;
    }

    return text.replace(
      "if (!realPath.startsWith(basePath)) throw new Error(`[escapes-base] '${virtualPath}' escapes '${basePath}'`)",
      "const deepestExistingBasePath = await getDeepestExistingPath(basePath)\n\t\tconst deepestExistingBaseRealPath = await fse.realpath(deepestExistingBasePath)\n\t\tconst baseRealPath = basePath.replace(deepestExistingBasePath, deepestExistingBaseRealPath)\n\n\t\tconst normalisedRealPath = normalizePath(realPath)\n\t\tconst normalisedBaseRealPath = normalizePath(baseRealPath)\n\t\tif (normalisedRealPath !== normalisedBaseRealPath && !normalisedRealPath.startsWith(`${normalisedBaseRealPath}/`)) {\n\t\t\tthrow new Error(`[escapes-base] '${virtualPath}' escapes '${basePath}'`)\n\t\t}",
    );
  });
}

function patchDbusAndFilesServices() {
  // Newer dbus module
  patchFile('packages/umbreld/source/modules/dbus/dbus.ts', (text) => {
    if (!text.includes("const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'")) {
      text = insertAfter(
        text,
        "import type Umbreld from '../../index.js'\n",
        "\nconst UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'\nconst UMBREL_RUNTIME_PROFILE = process.env.UMBREL_RUNTIME_PROFILE ?? 'minimal'\nconst UMBREL_SKIP_SYSTEM_SERVICES = UMBREL_DOCKER_MODE && UMBREL_RUNTIME_PROFILE !== 'compat'\n",
      );
    }
    if (!text.includes('Skipping dbus in docker minimal profile')) {
      text = text.replace(
        'async start() {\n',
        "async start() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) {\n\t\t\tthis.logger.log('Skipping dbus in docker minimal profile')\n\t\t\treturn\n\t\t}\n\n",
      );
    }
    return text;
  });

  // Older dbus module (1.4.0)
  patchFile('packages/umbreld/source/modules/dbus/index.ts', (text) => {
    if (!text.includes('UMBREL_DOCKER_MODE === \'true\'')) {
      text = insertAfter(
        text,
        "import UDisks from './udisks.js'\n",
        "\nconst UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'\nconst UMBREL_RUNTIME_PROFILE = process.env.UMBREL_RUNTIME_PROFILE ?? 'minimal'\nconst UMBREL_SKIP_SYSTEM_SERVICES = UMBREL_DOCKER_MODE && UMBREL_RUNTIME_PROFILE !== 'compat'\n",
      );
    }
    if (!text.includes('Skipping DBus in docker minimal profile')) {
      text = text.replace(
        'async start() {\n',
        "async start() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) {\n\t\t\tthis.logger.log('Skipping DBus in docker minimal profile')\n\t\t\treturn\n\t\t}\n\n",
      );
    }
    if (!text.includes('if (UMBREL_SKIP_SYSTEM_SERVICES) return')) {
      text = text.replace('async stop() {\n', 'async stop() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) return\n\n');
    }
    return text;
  });

  patchFile('packages/umbreld/source/modules/files/samba.ts', (text) => {
    if (!text.includes("const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'")) {
      const constants = "\nconst UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'\n";
      text = insertAfterImportBlock(text, constants);
    }

    text = text.replace(
      "async start() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) {\n\t\t\tthis.logger.log('Skipping samba in docker minimal profile')\n\t\t\treturn\n\t\t}\n\n",
      'async start() {\n',
    );

    text = text.replace(
      'async stop() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) return\n\n',
      'async stop() {\n',
    );

    if (!text.includes('/var/log/samba/log.%m')) {
      text = text.replace(
        '# Use Systemd for logging.\n# Samba still tries to log to file, so pipe that to /dev/null.\nlogging = systemd\nlog file = /dev/null\n',
        '# Use file logging in Docker where journald is not available.\nlogging = file\nlog file = /var/log/samba/log.%m\nmax log size = 1000\n',
      );
    }

    if (!text.includes('smbcontrol all shutdown')) {
      text = text.replace(
        "\tasync stop() {\n\t\tthis.logger.log('Stopping samba')\n\t\tthis.#removeFileChangeListener?.()\n\t\tawait $`systemctl stop smbd`.catch((error) => this.logger.error(`Failed to stop samba`, error))\n\t\tawait $`systemctl stop wsdd2`.catch((error) => this.logger.error(`Failed to stop wsdd2`, error))\n\t}\n",
        "\tasync stop() {\n\t\tthis.logger.log('Stopping samba')\n\t\tthis.#removeFileChangeListener?.()\n\n\t\tif (UMBREL_DOCKER_MODE) {\n\t\t\tawait $`smbcontrol all shutdown`.catch(async (error) => {\n\t\t\t\tthis.logger.error(`Failed to stop samba via smbcontrol`, error)\n\t\t\t\tawait $`pkill -x smbd`.catch((killError) => this.logger.error(`Failed to stop samba`, killError))\n\t\t\t})\n\t\t\tawait $`pkill -x wsdd2`.catch(() => {})\n\t\t\treturn\n\t\t}\n\n\t\tawait $`systemctl stop smbd`.catch((error) => this.logger.error(`Failed to stop samba`, error))\n\t\tawait $`systemctl stop wsdd2`.catch((error) => this.logger.error(`Failed to stop wsdd2`, error))\n\t}\n",
      );
    }

    if (!text.includes('smbd -D --configfile=/etc/samba/smb.conf')) {
      text = text.replace(
        "\t\t// Write out Samba config\n\t\tawait fse.writeFile('/etc/samba/smb.conf', config)\n\n\t\t// If we don't have any shares, ensure samba isn't running and return\n\t\tif (shares.length === 0) return await $`systemctl stop smbd`\n\n\t\t// Otherwise start samba, or reload it's config if it's already running\n\t\tawait $`systemctl start smbd`\n\t\tawait $`smbcontrol smbd reload-config`\n\n\t\t// We also start wsdd2 for better Windows discovery.\n\t\t// We need to manually start this along with samba because if we boot with wsdd2\n\t\t// enabled but without samba it will shutdown when it sees samba isn't running.\n\t\t// It won't then auto start if a share is added later.\n\t\tawait $`systemctl start wsdd2`\n",
        "\t\t// Write out Samba config\n\t\tawait fse.ensureDir('/var/log/samba')\n\t\tawait fse.ensureDir('/run/samba')\n\t\tawait fse.writeFile('/etc/samba/smb.conf', config)\n\n\t\tif (UMBREL_DOCKER_MODE) {\n\t\t\t// If we don't have any shares, ensure samba isn't running and return.\n\t\t\tif (shares.length === 0) {\n\t\t\t\tawait $`smbcontrol all shutdown`.catch(async () => {\n\t\t\t\t\tawait $`pkill -x smbd`.catch(() => {})\n\t\t\t\t})\n\t\t\t\tawait $`pkill -x wsdd2`.catch(() => {})\n\t\t\t\treturn\n\t\t\t}\n\n\t\t\t// Otherwise start samba if needed and reload its config.\n\t\t\tconst smbdRunning = await $`pgrep -x smbd`.then(() => true).catch(() => false)\n\t\t\tif (!smbdRunning) await $`smbd -D --configfile=/etc/samba/smb.conf`\n\t\t\tawait $`smbcontrol smbd reload-config`\n\n\t\t\t// Start wsdd2 in daemon mode for Windows discovery if it is not already running.\n\t\t\tconst wsdd2Running = await $`pgrep -x wsdd2`.then(() => true).catch(() => false)\n\t\t\tif (!wsdd2Running) {\n\t\t\t\tawait $`wsdd2 -d`.catch((error) => this.logger.error(`Failed to start wsdd2`, error))\n\t\t\t}\n\t\t\treturn\n\t\t}\n\n\t\t// If we don't have any shares, ensure samba isn't running and return\n\t\tif (shares.length === 0) return await $`systemctl stop smbd`\n\n\t\t// Otherwise start samba, or reload it's config if it's already running\n\t\tawait $`systemctl start smbd`\n\t\tawait $`smbcontrol smbd reload-config`\n\n\t\t// We also start wsdd2 for better Windows discovery.\n\t\t// We need to manually start this along with samba because if we boot with wsdd2\n\t\t// enabled but without samba it will shutdown when it sees samba isn't running.\n\t\t// It won't then auto start if a share is added later.\n\t\tawait $`systemctl start wsdd2`\n",
      );
    }

    return text;
  });

  const patchWatcherFile = (relPath) =>
    patchFile(relPath, (text) => {
      if (!text.includes("const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'")) {
        const constants =
          "const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'\nconst UMBREL_RUNTIME_PROFILE = process.env.UMBREL_RUNTIME_PROFILE ?? 'minimal'\nconst UMBREL_SKIP_SYSTEM_SERVICES = UMBREL_DOCKER_MODE && UMBREL_RUNTIME_PROFILE !== 'compat'\n";
        text = insertAfterImportBlock(text, constants);
      }

      if (!text.includes('Skipping files watcher in docker minimal profile')) {
        text = text.replace(
          'async start() {\n',
          "async start() {\n\t\tif (UMBREL_SKIP_SYSTEM_SERVICES) {\n\t\t\tthis.logger.log('Skipping files watcher in docker minimal profile')\n\t\t\treturn\n\t\t}\n\n",
        );
      }

      return text;
    });

  patchWatcherFile('packages/umbreld/source/modules/files/watcher.ts');
  patchWatcherFile('packages/umbreld/source/modules/files/files-watcher.ts');
}

function patchNetworkStorage() {
  patchFile('packages/umbreld/source/modules/files/network-storage.ts', (text) => {
    if (text.includes('let targetHost = host')) return text;

    const replacement =
      "let targetHost = host\n" +
      "\t\tif (host.endsWith('.local')) {\n" +
      "\t\t\ttry {\n" +
      "\t\t\t\tconst resolved = await $`avahi-resolve-host-name -4 ${host}`\n" +
      "\t\t\t\tconst [, address] = resolved.stdout.trim().split(/\\s+/)\n" +
      "\t\t\t\tif (address) targetHost = address\n" +
      "\t\t\t} catch {\n" +
      "\t\t\t\tthis.logger.verbose(`Failed to resolve mDNS host ${host} for smbclient`)\n" +
      "\t\t\t}\n" +
      "\t\t}\n" +
      "\t\tconst smbclient = await $`smbclient --list //${targetHost} --user ${username} --password ${password} --grepable`";
    return text.replace(
      "const smbclient = await $`smbclient --list //${host} --user ${username} --password ${password} --grepable`",
      () => replacement,
    );
  });
}

function patchSystemModules() {
  const files = [
    'packages/umbreld/source/modules/system.ts',
    'packages/umbreld/source/modules/system/system.ts',
  ];

  for (const relPath of files) {
    patchFile(relPath, (text) => {
      if (!text.includes("const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'")) {
        text = text.replace(
          /export async function getCpuTemperature\(\): Promise<\{/,
          "const UMBREL_DOCKER_MODE = process.env.UMBREL_DOCKER_MODE === 'true'\n\nexport async function getCpuTemperature(): Promise<{",
        );
      }

      text = text.replace(
        "if (typeof cpuTemperature.main !== 'number') throw new Error('Could not get CPU temperature')",
        "if (typeof cpuTemperature.main !== 'number') {\n\t\tif (UMBREL_DOCKER_MODE) return {warning: 'normal', temperature: 0}\n\t\tthrow new Error('Could not get CPU temperature')\n\t}",
      );

      text = text.replace(
        /export async function hasWifi\(\) \{[\s\S]*?return networkDevices\.includes\('wifi'\)\n\}/,
        () =>
          "export async function hasWifi() {\n\tif (UMBREL_DOCKER_MODE) return false\n\n\ttry {\n\t\tconst {stdout} = await $`nmcli --terse --fields TYPE device status`\n\t\tconst networkDevices = stdout.split('\\n')\n\t\treturn networkDevices.includes('wifi')\n\t} catch {\n\t\treturn false\n\t}\n}",
      );

      text = text.replace(
        /export async function getWifiNetworks\(\) \{[\s\S]*?return filteredNetworks\n\}/,
        () =>
          "export async function getWifiNetworks() {\n\tif (UMBREL_DOCKER_MODE) return []\n\n\ttry {\n\t\tconst listNetworks = await $`nmcli --terse --fields IN-USE,SSID,SECURITY,SIGNAL device wifi list`\n\n\t\t// Format into object\n\t\tconst networks = listNetworks.stdout.split('\\n').map((item: string) => {\n\t\t\tconst [inUse, ssid, security, signal] = item.split(':')\n\t\t\treturn {\n\t\t\t\tactive: inUse === '*',\n\t\t\t\tssid,\n\t\t\t\tauthenticated: !!security,\n\t\t\t\tsignal: parseInt(signal),\n\t\t\t}\n\t\t})\n\n\t\tconst filteredNetworks = networks\n\t\t\t// Remove duplicate and empty SSIDs\n\t\t\t.filter((network, index, list) => {\n\t\t\t\tif (network.ssid === '') return false\n\t\t\t\tconst indexOfFirstEntry = list.findIndex((item) => item.ssid === network.ssid)\n\t\t\t\treturn indexOfFirstEntry === index\n\t\t\t})\n\t\t\t// Reapply active status in case it got removed in filtering\n\t\t\t.map((network) => {\n\t\t\t\tnetwork.active = network.active || networks.some((item) => item.ssid === network.ssid && item.active)\n\t\t\t\treturn network\n\t\t\t})\n\t\t\t// Order by SSID\n\t\t\t.sort((a, b) => a.ssid.localeCompare(b.ssid))\n\n\t\treturn filteredNetworks\n\t} catch {\n\t\treturn []\n\t}\n}",
      );

      text = text.replace(
        /export async function deleteWifiConnections\(\{inactiveOnly = false\}: \{inactiveOnly\?: boolean\}\) \{[\s\S]*?\n\}/,
        () =>
          "export async function deleteWifiConnections({inactiveOnly = false}: {inactiveOnly?: boolean}) {\n\tif (UMBREL_DOCKER_MODE) return\n\n\tconst connections = await $`nmcli --terse --fields UUID,TYPE,ACTIVE connection`\n\tfor (const connection of connections.stdout.split('\\n')) {\n\t\tconst [uuid, type, active] = connection.split(':')\n\t\t// Type will be something like '802-11-wireless'\n\t\tif (!type?.includes('wireless')) continue\n\t\tif (inactiveOnly && active === 'yes') continue\n\t\tawait $`nmcli connection delete ${uuid}`\n\t}\n}",
      );

      text = text.replace(
        /export async function connectToWiFiNetwork\(\{ssid, password\}: \{ssid: string; password\?: string\}\) \{/,
        "export async function connectToWiFiNetwork({ssid, password}: {ssid: string; password?: string}) {\n\tif (UMBREL_DOCKER_MODE) throw new Error('WiFi not supported in docker mode')",
      );

      return text;
    });
  }
}

function run() {
  patchComposeNetwork();
  patchCommitPartition();
  patchFilesPathValidation();
  patchDbusAndFilesServices();
  patchNetworkStorage();
  patchIsUmbrelHome();
  patchAppsTs();
  patchAppEnvironment();
  patchAppScriptTs();
  patchLegacyAppScript();
  patchUpdateModules();
  patchSystemRoutes();
  patchSystemModules();
}

run();
