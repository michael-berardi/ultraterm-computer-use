// Privacy regression guard: shipped sources must not reintroduce telemetry,
// analytics or crash-reporting SDKs/endpoints, and user install paths must
// keep dependency analytics off.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { inspectConfig } from "../scripts/node-repl/config.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const selfStat = statSync(fileURLToPath(import.meta.url));

const SHIPPED_DIRS = ["apps", "packages", "plugins", "skills", "scripts"];
const SHIPPED_FILES = ["README.md", "SECURITY.md", "package.json", "Package.swift", "Package.resolved"];
const SKIP_DIRS = new Set([".git", "node_modules", "dist", "build", ".build", "test", "tests", "Tests", "Test", "fixtures"]);
const TEXT_EXT = /\.(md|json|py|ts|js|mjs|cjs|swift|sh|go|toml|yml|yaml|txt|xml|plist)$/i;

// Known services and SDKs. Deliberately specific: ordinary words such as
// "analytics" in documentation are not themselves a violation.
const TELEMETRY = [
  /\b(?:posthog|mixpanel|amplitude|datadog|bugsnag|sentry|heap analytics|intercom|new relic|newrelic|firebase analytics|google analytics|googleanalytics|gtag|googletagmanager|opentelemetry|otel exporter|appcenter|statsig|cloudflare insights|branch\.io|appsflyer)\b|@segment\/|\bsegment[-_]analytics\b|\bsegment\.io\b/i,
  /(?:api\.mixpanel\.com|api\.segment\.io|api\.amplitude\.com|app\.posthog\.com|browser\.sentry\.io|ingest\.sentry\.io|www\.google-analytics\.com|analytics\.google\.com|collect\.google-analytics\.com|dc\.services\.visualstudio\.com|ingest\.statsig\.com|cdn\.branch\.io)/i,
];

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name)) continue;
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory()) walk(path, out);
    else if (TEXT_EXT.test(name) && (st.dev !== selfStat.dev || st.ino !== selfStat.ino)) out.push(path);
  }
  return out;
}

const shipped = [
  ...SHIPPED_DIRS.flatMap((dir) => (exists(dir) ? walk(join(root, dir)) : [])),
  ...SHIPPED_FILES.filter((name) => exists(name)).map((name) => join(root, name)),
];

function exists(name) {
  try { statSync(join(root, name)); return true; } catch { return false; }
}

function hits() {
  return shipped.flatMap((file) =>
    readFileSync(file, "utf8").split("\n").flatMap((line, index) =>
      TELEMETRY.filter((pattern) => pattern.test(line))
        .map((pattern) => `${relative(root, file)}:${index + 1}: ${pattern.source}`)
    )
  );
}

test("shipped sources contain no telemetry or analytics SDKs or endpoints", () => {
  assert.ok(shipped.length > 0, "shipped source list is empty");
  assert.deepEqual(hits(), []);
});

test("the guard detects a known-bad endpoint", () => {
  assert.match("fetch('https://api.mixpanel.com/track')", TELEMETRY[1]);
  assert.match("import posthog from 'posthog-js'", TELEMETRY[0]);
  assert.match("import Analytics from '@segment/analytics-node'", TELEMETRY[0]);
});

test("install and release paths disable dependency analytics", () => {
  for (const name of ["scripts/install.sh", "scripts/install.ps1", "scripts/npm/publish-packages.mjs", "scripts/release-package.sh"]) {
    assert.match(readFileSync(join(root, name), "utf8"), /DO_NOT_TRACK/, `${name} must set DO_NOT_TRACK`);
  }
  assert.match(readFileSync(join(root, "scripts/install.sh"), "utf8"), /npm_config_update_notifier=false/);
  assert.match(readFileSync(join(root, "scripts/install.ps1"), "utf8"), /npm_config_update_notifier/);
});

test("default config has no network settings", () => {
  const home = mkdtempSync(join(tmpdir(), "ocu-privacy-"));
  try {
    const report = inspectConfig({ HOME: home, XDG_CONFIG_HOME: home });
    assert.equal(report.path, join(home, "ultraterm-computer-use", "config.json"));
    assert.ok(Object.values(report.values).every((value) => typeof value !== "string" || !value.includes("://")),
      "default settings must not contain URLs");
    assert.ok(Object.values(report.sources).every((source) => source === "default"));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
