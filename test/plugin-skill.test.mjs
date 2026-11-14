import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const plugin = path.join(root, "plugins", "ultraterm-computer-use");
const skillName = "ultraterm-computer-use";

function files(directory, prefix = "") {
  return readdirSync(directory).sort().flatMap((entry) => {
    const full = path.join(directory, entry);
    return statSync(full).isDirectory() ? files(full, `${prefix}${entry}/`) : [`${prefix}${entry}`];
  });
}

test("the plugin registers no MCP server by default and ships the skill", () => {
  const manifest = JSON.parse(readFileSync(path.join(plugin, ".codex-plugin", "plugin.json"), "utf8"));
  assert.equal(manifest.mcpServers, undefined);
  assert.equal(manifest.skills, "./skills/");
  assert.equal(existsSync(path.join(plugin, ".mcp.json")), false, "a root .mcp.json is auto-discovered by some hosts");
  assert.equal(existsSync(path.join(plugin, "skills", skillName, "SKILL.md")), true);
});

test("the MCP entry exists only as an opt-in file", () => {
  const optional = JSON.parse(readFileSync(path.join(plugin, "optional", "mcp.json"), "utf8"));
  assert.ok(optional.mcpServers["ultraterm-computer-use"]);
  assert.match(readFileSync(path.join(plugin, "README.md"), "utf8"), /"mcpServers": "\.\/optional\/mcp\.json"/);
});

test("the plugin's skill is the repository skill", () => {
  const source = path.join(root, "skills", skillName);
  const copy = path.join(plugin, "skills", skillName);
  assert.deepEqual(files(copy), files(source));
  for (const file of files(source)) {
    assert.equal(readFileSync(path.join(copy, file), "utf8"), readFileSync(path.join(source, file), "utf8"), file);
  }
});

test("the skill drives the CLI first and treats MCP as optional", () => {
  const skill = readFileSync(path.join(root, "skills", skillName, "SKILL.md"), "utf8");
  assert.match(skill, /^---\nname: ultraterm-computer-use\n/);
  assert.match(skill, /needs no MCP server/);
  assert.doesNotMatch(skill, /"mcpServers"/);
  for (const reference of skill.matchAll(/\]\((references\/[^)]+)\)/g)) {
    assert.equal(existsSync(path.join(root, "skills", skillName, reference[1])), true, reference[1]);
  }
});
