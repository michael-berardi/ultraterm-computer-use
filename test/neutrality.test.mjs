// Neutrality guard modelled on Carl's neutrality.test.ts.
// The shipped tool must carry no built-in model id, provider preference, paid-route grant,
// profile, account name, person/client/project name, or operator-specific workflow.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));

// Shipped surfaces. scripts/ is included because the repo's install/release/CI helpers ship too.
const SHIPPED_DIRS = ["apps", "packages", "plugins", "skills", "docs", "scripts"];
const SHIPPED_FILES = [
  "README.md",
  "SECURITY.md",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "package.json",
  "Package.swift",
  "Makefile",
  "CODEOWNERS",
  ".gitignore",
  ".gitattributes",
  ".gitleaks.toml",
];

// Legal/upstream attribution is intentionally excluded; it names upstream authors and licenses.
const LEGAL_ATTRIBUTION = new Set(["LICENSE", "THIRD_PARTY_NOTICES.md"]);

// Tests' fixtures are excluded; they may contain example paths and synthetic identities.
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  ".build",
  "Tests",
  "test",
  "tests",
  "Test",
]);

const TEXT_EXT = /\.(md|json|py|ts|js|mjs|cjs|swift|sh|go|toml|yml|yaml|txt|html|css|xml|plist)$/i;

// Model ids and provider-routing strings that only an operator should choose.
const MODEL_CHOICE =
  /\b(?:gpt-\d[\w.-]*|deepseek-v\d[\w.-]*|opencode-go\/|:exacto\b|mimo-v\d|glm-\d|gemini-\d|sonnet-\d|haiku-\d|opus-\d|o[134]-mini|o[134]-preview)/i;

// Operator-specific organisation, person, client, project, account, and machine-path strings.
const PERSONAL =
  /\b(?:Pareto|Implose|paretocybernetics|implosecybernetics|Mike|Berardi|michael-berardi|Michael Berardi|Dana|Felix|acme|acme|Mouseia|libertydesign|Liberty Design|acme|T63VT9UAY2)\b|\/Users\/[a-z]/i;

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (LEGAL_ATTRIBUTION.has(name) || SKIP_DIRS.has(name)) continue;
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory()) {
      walk(path, out);
    } else if (TEXT_EXT.test(name)) {
      out.push(path);
    }
  }
  return out;
}

const shipped = [
  ...SHIPPED_DIRS.flatMap((dir) => (existsSync(join(root, dir)) ? walk(join(root, dir)) : [])),
  ...SHIPPED_FILES.filter(
    (name) => existsSync(join(root, name)) && !LEGAL_ATTRIBUTION.has(name),
  ).map((name) => join(root, name)),
];

function scanFiles(files) {
  return files
    .flatMap((file) =>
      readFileSync(file, "utf8")
        .split("\n")
        .map((line, index) => [file, index + 1, line]),
    )
    .filter(([, , line]) => MODEL_CHOICE.test(line) || PERSONAL.test(line))
    .map(([file, line, text]) => `${relative(root, file)}:${line}: ${text.trim().slice(0, 120)}`);
}

test("shipped files carry no built-in model id or operator-specific name", () => {
  assert.ok(shipped.length > 0, "shipped file list is empty");
  assert.deepEqual(scanFiles(shipped), []);
});

test("neutrality scanner detects a known-bad string", () => {
  const dir = mkdtempSync(join(tmpdir(), "neutrality-"));
  try {
    const probe = join(dir, "probe.md");
    writeFileSync(probe, "Pareto Cybernetics\nopenai gpt-4\n");
    const hits = scanFiles([probe]);
    assert.ok(
      hits.length >= 2,
      `scanner failed to detect known-bad strings: ${JSON.stringify(hits)}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
