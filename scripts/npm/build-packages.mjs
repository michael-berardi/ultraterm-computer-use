#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const defaultOutDir = path.join(repoRoot, "dist", "npm");
const appBundleName = "UltraTerm Computer Use.app";
const appExecutableName = "UltraTermComputerUse";
const metaPackageNames = ["ultraterm-computer-use"];
const runtimeTargets = [
  {
    os: "darwin",
    cpu: "arm64",
    kind: "macos-app",
    executablePath: ["dist", appBundleName, "Contents", "MacOS", appExecutableName],
  },
  {
    os: "darwin",
    cpu: "x64",
    kind: "macos-app",
    executablePath: ["dist", appBundleName, "Contents", "MacOS", appExecutableName],
  },
  {
    os: "linux",
    cpu: "arm64",
    kind: "binary",
    buildArch: "arm64",
    executablePath: ["dist", "linux", "arm64", "ultraterm-computer-use"],
  },
  {
    os: "linux",
    cpu: "x64",
    kind: "binary",
    buildArch: "amd64",
    executablePath: ["dist", "linux", "amd64", "ultraterm-computer-use"],
  },
  {
    os: "win32",
    cpu: "arm64",
    kind: "binary",
    buildArch: "arm64",
    executablePath: ["dist", "windows", "arm64", "ultraterm-computer-use.exe"],
  },
  {
    os: "win32",
    cpu: "x64",
    kind: "binary",
    buildArch: "amd64",
    executablePath: ["dist", "windows", "amd64", "ultraterm-computer-use.exe"],
  },
];
const packageNames = [
  ...metaPackageNames,
];

export const placeholderSlug = "your-org/ultraterm-computer-use";
const slugPattern = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const remotePattern = /^(?:git@github\.com:|ssh:\/\/git@github\.com\/|https:\/\/github\.com\/)([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?\/?$/;

export function isValidSlug(slug) {
  return typeof slug === "string" && slugPattern.test(slug);
}

// Same rules as scripts/stamp-installers.sh: https and ssh GitHub forms, with or without .git.
export function slugFromRemoteUrl(url) {
  const match = remotePattern.exec(String(url ?? "").trim());
  return match ? `${match[1]}/${match[2]}` : "";
}

// Env override first, then the origin remote. Returns "" when nothing usable is found.
export function resolveReleaseSlug({ env = process.env, remoteUrl = "" } = {}) {
  const override = env.ULTRATERM_COMPUTER_USE_RELEASE_REPO ?? "";
  if (override) {
    return isValidSlug(override) ? override : "";
  }
  return slugFromRemoteUrl(remoteUrl);
}

export function readOriginRemote(cwd = repoRoot) {
  const result = spawnSync("git", ["-C", cwd, "remote", "get-url", "origin"], { encoding: "utf-8" });
  return result.status === 0 ? result.stdout.trim() : "";
}

// Returns the slug to stamp, or "" when a debug build may keep the placeholder.
// Release builds throw a named error instead.
export function requireSlug({ configuration, env = process.env, remoteUrl = "" }) {
  const slug = resolveReleaseSlug({ env, remoteUrl });
  if (slug && slug !== placeholderSlug) {
    return slug;
  }
  if (configuration !== "release") {
    return "";
  }
  const cause = slug
    ? `the owner/repo is still the placeholder ${placeholderSlug}`
    : "cannot tell the GitHub owner/repo (ULTRATERM_COMPUTER_USE_RELEASE_REPO is unset or invalid and there is no GitHub origin remote)";
  throw new Error(`build-packages: ${cause}; set ULTRATERM_COMPUTER_USE_RELEASE_REPO=owner/repo or add a GitHub origin remote, or build with --configuration debug to keep the placeholder.`);
}

export function stampText(text, slug) {
  return text.split(placeholderSlug).join(slug);
}

function walkFiles(root, visit) {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      // Bundled native runtimes are binary; they are not text files.
      if (entry.name === "dist" && path.dirname(full) === root) continue;
      walkFiles(full, visit);
    } else if (entry.isFile()) {
      visit(full);
    }
  }
}

function readTextFile(filePath) {
  const buffer = readFileSync(filePath);
  return buffer.includes(0) ? undefined : buffer.toString("utf-8");
}

export function stampStagedPackage(packageRoot, slug) {
  let stamped = 0;
  walkFiles(packageRoot, (filePath) => {
    const text = readTextFile(filePath);
    if (text === undefined || !text.includes(placeholderSlug)) return;
    writeFileSync(filePath, stampText(text, slug), { encoding: "utf-8", mode: statSync(filePath).mode });
    stamped += 1;
  });
  return stamped;
}

export function findPlaceholders(packageRoot) {
  const found = [];
  walkFiles(packageRoot, (filePath) => {
    const text = readTextFile(filePath);
    if (text !== undefined && text.includes(placeholderSlug)) found.push(path.relative(packageRoot, filePath));
  });
  return found;
}

export function assertNoPlaceholders(packageRoot) {
  const found = findPlaceholders(packageRoot);
  if (found.length > 0) {
    throw new Error(`build-packages: the placeholder ${placeholderSlug} survived in the staged package: ${found.join(", ")}`);
  }
}

export function stagedAppHasLockedUse(appPath) {
  return existsSync(path.join(appPath, "Contents", "Resources", "LockedUse"));
}

function parseArgs(argv) {
  const options = {
    arch: "universal",
    configuration: "release",
    outDir: defaultOutDir,
    packageNames: [...packageNames],
    skipBuild: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--arch":
        options.arch = argv[index + 1];
        index += 1;
        break;
      case "--configuration":
        options.configuration = argv[index + 1];
        index += 1;
        break;
      case "--out-dir":
        options.outDir = path.resolve(repoRoot, argv[index + 1]);
        index += 1;
        break;
      case "--package":
        options.packageNames = [argv[index + 1]];
        index += 1;
        break;
      case "--skip-build":
        options.skipBuild = true;
        break;
      case "-h":
      case "--help":
        printHelp();
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  for (const packageName of options.packageNames) {
    if (!packageNames.includes(packageName)) {
      throw new Error(`Unsupported package name: ${packageName}`);
    }
  }

  return options;
}

function printHelp() {
  process.stdout.write(`Usage: node ./scripts/npm/build-packages.mjs [options]

Options:
  --configuration debug|release
  --arch native|arm64|x86_64|universal  macOS app build arch. Defaults to universal.
  --out-dir <dir>
  --package <package-name>
  --skip-build

Packages:
${packageNames.map((name) => `  - ${name}`).join("\n")}
`);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    stdio: "inherit",
    ...options,
  });

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with exit code ${result.status ?? "unknown"}`);
  }
}

function readJSON(filePath) {
  return JSON.parse(readFileSync(filePath, "utf-8"));
}

function removeJunkFiles(targetPath) {
  if (!existsSync(targetPath)) {
    return;
  }

  const entryStat = statSync(targetPath);
  if (entryStat.isDirectory()) {
    for (const entry of readdirSync(targetPath)) {
      removeJunkFiles(path.join(targetPath, entry));
    }
    return;
  }

  if (path.basename(targetPath) === ".DS_Store") {
    unlinkSync(targetPath);
  }
}

function ensureBuilt(configuration, arch) {
  run(path.join(repoRoot, "scripts", "build-ultraterm-computer-use-app.sh"), [
    "--configuration",
    configuration,
    "--arch",
    arch,
  ]);

  for (const buildArch of ["arm64", "amd64"]) {
    run(path.join(repoRoot, "scripts", "build-ultraterm-computer-use-linux.sh"), [
      "--configuration",
      configuration,
      "--arch",
      buildArch,
    ]);
    run(path.join(repoRoot, "scripts", "build-ultraterm-computer-use-windows.sh"), [
      "--configuration",
      configuration,
      "--arch",
      buildArch,
    ]);
  }
}

function writeExecutable(filePath, content) {
  writeFileSync(filePath, content, "utf-8");
  chmodSync(filePath, 0o755);
}

function platformLaunchTable() {
  return Object.fromEntries(
    runtimeTargets.map((runtimeTarget) => [
      `${runtimeTarget.os}-${runtimeTarget.cpu}`,
      {
        executablePath: runtimeTarget.executablePath,
      },
    ]),
  );
}

function renderLauncher() {
  return `#!/usr/bin/env node
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const platformPackages = ${JSON.stringify(platformLaunchTable(), null, 2)};
const packageRoot = path.resolve(__dirname, "..");
const cliModule = pathToFileURL(path.join(packageRoot, "scripts", "node-repl", "ultraterm-computer-use-cli.mjs")).href;

import(cliModule)
  .then(({ main }) => main({ packageRoot, platformPackages }))
  .then(code => { process.exitCode = Number.isInteger(code) ? code : 1; })
  .catch(error => {
    console.error(\`ultraterm-computer-use: \${error instanceof Error ? error.message : String(error)}\`);
    process.exitCode = 1;
  });
`;
}

function renderPostinstall(packageName, version) {
  return `#!/usr/bin/env node
const mcpConfig = ${JSON.stringify({
  mcpServers: {
    "ultraterm-computer-use": {
      command: "ultraterm-computer-use",
      args: ["mcp"],
    },
  },
}, null, 2)};
const lines = [
  "",
  "Installed ${packageName}@${version}.",
  "Package: https://www.npmjs.com/package/${packageName}",
  "Command: ultraterm-computer-use",
  "Native runtime will be selected from bundled artifacts for " + process.platform + "-" + process.arch + ".",
  "",
  "Next:",
  "1. Run ultraterm-computer-use --version or ultraterm-computer-use capabilities",
  "2. Add the MCP config below to your host client, or use ultraterm-computer-use js / ultraterm-computer-use repl directly",
  "3. On macOS, run ultraterm-computer-use doctor and grant Accessibility / Screen Recording if prompted",
  "",
  "MCP config:",
  JSON.stringify(mcpConfig, null, 2),
  "",
];
for (const line of lines) {
  console.log(line);
}
`;
}

function renderReadme(packageName, version) {
  return `# ${packageName}

Cross-platform npm distribution for the open-source **UltraTerm Computer Use** MCP server.

This package bundles native runtimes for these supported platforms and lets the Node launcher choose the current \`process.platform\` / \`process.arch\` pair:

${runtimeTargets.map((runtimeTarget) => `- \`${runtimeTarget.os}-${runtimeTarget.cpu}\``).join("\n")}

Global command:

- \`ultraterm-computer-use\`

## Install

\`\`\`bash
npm install -g ${packageName}
\`\`\`

The root launcher resolves the current \`process.platform\` / \`process.arch\` pair and runs the matching bundled native runtime.

## MCP config

If your MCP client accepts a stdio-style \`mcpServers\` JSON config, this is the default setup:

\`\`\`json
{
  "mcpServers": {
    "ultraterm-computer-use": {
      "command": "ultraterm-computer-use",
      "args": ["mcp"]
    }
  }
}
\`\`\`

Package page: https://www.npmjs.com/package/${packageName}

## Use

\`\`\`bash
ultraterm-computer-use --version
ultraterm-computer-use --help
ultraterm-computer-use mcp
ultraterm-computer-use mcp
ultraterm-computer-use capabilities
ultraterm-computer-use capabilities --json
ultraterm-computer-use js 'nodeRepl.write(6 * 7)'
printf 'var answer = 40\nanswer += 2; nodeRepl.write(answer)\n.exit\n' | ultraterm-computer-use repl
ultraterm-computer-use call list_apps
ultraterm-computer-use help click

# macOS permission check and onboarding
ultraterm-computer-use doctor

# Installer helpers for MCP-capable CLIs
ultraterm-computer-use install-claude-mcp
ultraterm-computer-use install-gemini-mcp
ultraterm-computer-use install-gemini-mcp --scope user
ultraterm-computer-use install-codex-mcp
ultraterm-computer-use install-opencode-mcp
ultraterm-computer-use install-codex-plugin
\`\`\`

## Notes

- Version: \`${version}\`
- Supported npm platforms: \`darwin-arm64\`, \`darwin-x64\`, \`linux-arm64\`, \`linux-x64\`, \`win32-arm64\`, \`win32-x64\`
- \`ultraterm-computer-use js\` creates a one-shot JavaScript/native session; \`ultraterm-computer-use repl\` keeps one session for the current terminal and preserves bindings between evaluations.
- Both code-first commands use the Node executable that started the npm launcher. The npm launcher itself still requires Node.js 18 or newer to be available when the command starts.
- \`ultraterm-computer-use mcp\` is optional and exposes the same tools as \`call\` (the skill drives the CLI and needs no MCP server). The Codex plugin does not register it by default; its opt-in JavaScript adapter exposes \`js\` / \`js_reset\`.
- macOS still requires \`Accessibility\` and \`Screen Recording\` permissions.
- Linux requires a signed-in desktop session with AT-SPI2 / D-Bus accessibility available for real app control.
- Windows requires a signed-in desktop session for UI Automation access.

Source repository: https://github.com/your-org/ultraterm-computer-use
`;
}

function packageKeywords(extraKeywords = []) {
  return [
    "computer-use",
    "codex",
    "mcp",
    "macos",
    "linux",
    "windows",
    "automation",
    ...extraKeywords,
  ];
}

function renderMetaPackageJson(packageName, version) {
  return {
    name: packageName,
    version,
    description: "Cross-platform Computer Use MCP server launcher. After install, configure ultraterm-computer-use mcp.",
    license: "MIT",
    homepage: "https://github.com/your-org/ultraterm-computer-use",
    repository: {
      type: "git",
      url: "git+https://github.com/your-org/ultraterm-computer-use.git",
    },
    bugs: {
      url: "https://github.com/your-org/ultraterm-computer-use/issues",
    },
    keywords: packageKeywords(),
    engines: {
      node: ">=18",
    },
    preferGlobal: true,
    publishConfig: {
      access: "public",
    },
    bin: {
      "ultraterm-computer-use": "bin/ultraterm-computer-use",
    },
    scripts: {
      postinstall: "node ./scripts/postinstall.mjs",
    },
    files: [
      ".agents/plugins/marketplace.json",
      "bin/",
      "dist/UltraTerm Computer Use.app/",
      "dist/linux/",
      "dist/windows/",
      "plugins/ultraterm-computer-use/.codex-plugin/",
      "plugins/ultraterm-computer-use/optional/",
      "plugins/ultraterm-computer-use/skills/",
      "plugins/ultraterm-computer-use/assets/",
      "plugins/ultraterm-computer-use/scripts/",
      "scripts/install-claude-mcp.sh",
      "scripts/install-gemini-mcp.sh",
      "scripts/install-config-helper.mjs",
      "scripts/install-codex-mcp.sh",
      "scripts/install-opencode-mcp.sh",
      "scripts/install-dsh-mcp.sh",
      "scripts/install-codex-plugin.sh",
      "scripts/node-repl/",
      "scripts/postinstall.mjs",
      "skills/ultraterm-computer-use/",
      "README.md",
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
    ],
  };
}

function copyInstallerScripts(packageRoot) {
  cpSync(path.join(repoRoot, "scripts", "install-claude-mcp.sh"), path.join(packageRoot, "scripts", "install-claude-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-gemini-mcp.sh"), path.join(packageRoot, "scripts", "install-gemini-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-config-helper.mjs"), path.join(packageRoot, "scripts", "install-config-helper.mjs"));
  cpSync(path.join(repoRoot, "scripts", "install-codex-mcp.sh"), path.join(packageRoot, "scripts", "install-codex-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-opencode-mcp.sh"), path.join(packageRoot, "scripts", "install-opencode-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-dsh-mcp.sh"), path.join(packageRoot, "scripts", "install-dsh-mcp.sh"));
  cpSync(path.join(repoRoot, "scripts", "install-codex-plugin.sh"), path.join(packageRoot, "scripts", "install-codex-plugin.sh"));
  cpSync(path.join(repoRoot, "skills", "ultraterm-computer-use"), path.join(packageRoot, "skills", "ultraterm-computer-use"), { recursive: true });
  mkdirSync(path.join(packageRoot, "scripts", "node-repl"), { recursive: true });
  for (const scriptName of [
    "ultraterm-computer-use-cli.mjs",
    "config.mjs",
    "ultraterm-computer-use-repl.mjs",
    "ultraterm-computer-use-kernel.mjs",
  ]) {
    cpSync(
      path.join(repoRoot, "scripts", "node-repl", scriptName),
      path.join(packageRoot, "scripts", "node-repl", scriptName),
    );
  }
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "config.mjs"),
    path.join(packageRoot, "plugins", "ultraterm-computer-use", "scripts", "config.mjs")
  );
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "ultraterm-computer-use-repl.mjs"),
    path.join(packageRoot, "plugins", "ultraterm-computer-use", "scripts", "ultraterm-computer-use-repl.mjs")
  );
  cpSync(
    path.join(repoRoot, "scripts", "node-repl", "ultraterm-computer-use-kernel.mjs"),
    path.join(packageRoot, "plugins", "ultraterm-computer-use", "scripts", "ultraterm-computer-use-kernel.mjs")
  );

  for (const scriptName of [
    "install-claude-mcp.sh",
    "install-gemini-mcp.sh",
    "install-codex-mcp.sh",
    "install-opencode-mcp.sh",
    "install-dsh-mcp.sh",
    "install-codex-plugin.sh",
  ]) {
    chmodSync(path.join(packageRoot, "scripts", scriptName), 0o755);
  }
}

function assertFileExists(filePath, packageName) {
  if (!existsSync(filePath)) {
    throw new Error(`Missing artifact for ${packageName}: ${filePath}. Run without --skip-build first.`);
  }
}

function copyBundledRuntimes(packageRoot, packageName) {
  const distRoot = path.join(packageRoot, "dist");
  mkdirSync(distRoot, { recursive: true });

  const macosSourcePath = path.join(repoRoot, "dist", appBundleName);
  const macosDestinationPath = path.join(distRoot, appBundleName);
  assertFileExists(macosSourcePath, packageName);
  cpSync(macosSourcePath, macosDestinationPath, { recursive: true });

  for (const platformDir of ["linux", "windows"]) {
    const sourcePath = path.join(repoRoot, "dist", platformDir);
    const destinationPath = path.join(distRoot, platformDir);
    assertFileExists(sourcePath, packageName);
    cpSync(sourcePath, destinationPath, { recursive: true });
  }

  for (const runtimeTarget of runtimeTargets) {
    const executablePath = path.join(packageRoot, ...runtimeTarget.executablePath);
    assertFileExists(executablePath, packageName);
    if (runtimeTarget.kind !== "macos-app") {
      chmodSync(executablePath, 0o755);
    }
  }
}

function stageMetaPackage(packageName, version, outDir, slug, configuration) {
  const packageRoot = path.join(outDir, packageName);
  rmSync(packageRoot, { recursive: true, force: true });

  mkdirSync(path.join(packageRoot, ".agents", "plugins"), { recursive: true });
  mkdirSync(path.join(packageRoot, "bin"), { recursive: true });
  mkdirSync(path.join(packageRoot, "dist"), { recursive: true });
  mkdirSync(path.join(packageRoot, "plugins"), { recursive: true });
  mkdirSync(path.join(packageRoot, "scripts"), { recursive: true });

  cpSync(path.join(repoRoot, ".agents", "plugins", "marketplace.json"), path.join(packageRoot, ".agents", "plugins", "marketplace.json"));
  cpSync(path.join(repoRoot, "plugins", "ultraterm-computer-use"), path.join(packageRoot, "plugins", "ultraterm-computer-use"), {
    recursive: true,
  });
  cpSync(path.join(repoRoot, "LICENSE"), path.join(packageRoot, "LICENSE"));
  cpSync(path.join(repoRoot, "THIRD_PARTY_NOTICES.md"), path.join(packageRoot, "THIRD_PARTY_NOTICES.md"));
  copyBundledRuntimes(packageRoot, packageName);
  copyInstallerScripts(packageRoot);

  const launcher = renderLauncher();
  writeExecutable(path.join(packageRoot, "bin", "ultraterm-computer-use"), launcher);
  writeFileSync(path.join(packageRoot, "scripts", "postinstall.mjs"), renderPostinstall(packageName, version), "utf-8");
  writeFileSync(path.join(packageRoot, "README.md"), renderReadme(packageName, version), "utf-8");
  writeFileSync(path.join(packageRoot, "package.json"), `${JSON.stringify(renderMetaPackageJson(packageName, version), null, 2)}\n`, "utf-8");

  if (slug) {
    stampStagedPackage(packageRoot, slug);
  }
  if (configuration === "release") {
    assertNoPlaceholders(packageRoot);
  }

  removeJunkFiles(packageRoot);
}

function stagePackage(packageName, version, outDir, slug, configuration) {
  if (!metaPackageNames.includes(packageName)) {
    throw new Error(`Unsupported package name: ${packageName}`);
  }

  stageMetaPackage(packageName, version, outDir, slug, configuration);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (process.env.ULTRATERM_COMPUTER_USE_APP_VARIANT) {
    throw new Error("ULTRATERM_COMPUTER_USE_APP_VARIANT is only supported by build-ultraterm-computer-use-app.sh; unset it before packaging.");
  }
  const slug = requireSlug({ configuration: options.configuration, remoteUrl: readOriginRemote() });
  const pluginManifestPath = path.join(repoRoot, "plugins", "ultraterm-computer-use", ".codex-plugin", "plugin.json");
  const { version } = readJSON(pluginManifestPath);

  if (!options.skipBuild) {
    ensureBuilt(options.configuration, options.arch);
  }

  const stagedApp = path.join(repoRoot, "dist", appBundleName);
  if (options.configuration === "release" && stagedAppHasLockedUse(stagedApp)) {
    run(path.join(repoRoot, "scripts", "verify-locked-use-bundle.sh"), [stagedApp]);
  }

  rmSync(options.outDir, { recursive: true, force: true });
  mkdirSync(options.outDir, { recursive: true });

  for (const packageName of options.packageNames) {
    stagePackage(packageName, version, options.outDir, slug, options.configuration);
  }

  process.stdout.write(`${options.outDir}\n`);
}

// Compare real paths: a temp folder is reached through a symlink on macOS (/var -> /private/var),
// and a plain string comparison would silently skip the build there.
function invokedDirectly() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(path.resolve(process.argv[1]));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
}
