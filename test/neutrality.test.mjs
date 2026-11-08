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
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const selfStat = statSync(fileURLToPath(import.meta.url));

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

// Generated directories are excluded.
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  ".build",
]);

const TEXT_EXT = /\.(md|json|py|ts|js|mjs|cjs|swift|sh|go|toml|yml|yaml|txt|html|css|xml|plist)$/i;

// Model ids and provider-routing strings that only an operator should choose.
const MODEL_CHOICE =
  /\b(?:gpt-\d[\w.-]*|deepseek-v\d[\w.-]*|opencode-go\/|:exacto\b|mimo-v\d|glm-\d|gemini-\d|sonnet-\d|haiku-\d|opus-\d|o[134]-mini|o[134]-preview)/i;

// Operator-specific organisation, person, client, project, account, and machine-path strings.
const PERSONAL =
  /\b(?:Pareto|Implose|paretocybernetics|implosecybernetics|Mike|Berardi|michael-berardi|Michael Berardi|Felix|Mouseia|libertydesign|Liberty Design|T63VT9UAY2)\b|\/Users\/[a-z]/i;

function privateTerms(file = process.env.OSS_PRIVATE_TERMS ?? join(homedir(), ".config/oss-audit/names.txt")) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  return text.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith("#"))
    .map((term) => {
      const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      return new RegExp(`${/^\w/.test(term) ? "\\b" : ""}${escaped}${/\w$/.test(term) ? "\\b" : ""}`, "i");
    });
}

function walk(dir, out = [], includeTests = false) {
  for (const name of readdirSync(dir)) {
    if (LEGAL_ATTRIBUTION.has(name) || SKIP_DIRS.has(name) || (!includeTests && ["test", "tests", "Tests", "Test"].includes(name))) continue;
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory()) {
      walk(path, out, includeTests);
    } else if (TEXT_EXT.test(name) && (st.dev !== selfStat.dev || st.ino !== selfStat.ino)) {
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

const personalFiles = [...new Set([...shipped, ...[...SHIPPED_DIRS, "test", "tests", "Tests", "Test"].flatMap((dir) =>
  existsSync(join(root, dir)) ? walk(join(root, dir), [], true) : []),
])];

function scanFiles(files, patterns = [MODEL_CHOICE, PERSONAL]) {
  return files
    .flatMap((file) =>
      readFileSync(file, "utf8")
        .split("\n")
        .map((line, index) => [file, index + 1, line]),
    )
    // The README credits the publisher on one line; it is public branding, not an operator identity.
    .filter(([file, , line]) => !(file.endsWith("README.md") && line.startsWith("Part of [Pareto Cybernetics](https://paretocybernetics.com/")))
    .filter(([, , line]) => patterns.some((pattern) => pattern.test(line)))
    .map(([file, line, text]) => `${relative(root, file)}:${line}: ${text.trim().slice(0, 120)}`);
}

test("shipped files carry no built-in model id or operator-specific name", () => {
  assert.ok(shipped.length > 0, "shipped file list is empty");
  assert.deepEqual(scanFiles(shipped), []);
  assert.deepEqual(scanFiles(personalFiles, [PERSONAL, ...privateTerms()]), []);
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

test("private terms loader matches literal bounded terms", () => {
  const dir = mkdtempSync(join(tmpdir(), "neutrality-"));
  try {
    const terms = join(dir, "terms.txt");
    const probe = join(dir, "probe.txt");
    writeFileSync(terms, "# comment\n\nzzqx-private.term\n");
    const patterns = privateTerms(terms);
    assert.equal(patterns.length, 1);
    writeFileSync(probe, "ZZQX-private.term\nneutral text zzqx-privateXterm\nazzqx-private.term\n");
    assert.deepEqual(privateTerms(join(dir, "missing")), []);
    assert.equal(scanFiles([probe], patterns).length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
