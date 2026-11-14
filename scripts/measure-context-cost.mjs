#!/usr/bin/env node
// Measures what an agent loads into its context: the MCP tool schemas and server instructions
// versus the skill text and per-tool CLI help. Usage: node scripts/measure-context-cost.mjs [path-to-ultraterm-computer-use]
// Only runs `tools --json` and `help <tool>`: both are offline and touch no app.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = process.argv[2] ?? "ultraterm-computer-use";
const bytes = (text) => Buffer.byteLength(text, "utf8");
const tokens = (n) => Math.round(n / 4); // rough: about 4 bytes per token for English and JSON

const tools = JSON.parse(execFileSync(binary, ["tools", "--json"], { encoding: "utf8" }));
const toolsList = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { tools } });
const server = readFileSync(path.join(root, "packages/UltraTermComputerUseKit/Sources/UltraTermComputerUseKit/MCPServer.swift"), "utf8");
const instructions = server.match(/let computerUseServerInstructions = """\n([\s\S]*?)\n"""/)[1];

const skill = readFileSync(path.join(root, "skills/ultraterm-computer-use/SKILL.md"), "utf8");
const frontmatter = skill.match(/^---\n([\s\S]*?)\n---\n/)[1];
const body = skill.slice(frontmatter.length + 9);
const help = (name) => bytes(execFileSync(binary, ["help", name], { encoding: "utf8" }));
const typical = ["get_app_state", "click", "type_text"].reduce((sum, name) => sum + help(name), 0);

const mcpAlways = bytes(toolsList) + bytes(instructions);
const skillAlways = bytes(frontmatter);
const skillUsed = skillAlways + bytes(body) + typical;
const rows = [
  ["MCP tools/list result", bytes(toolsList)],
  ["MCP initialize instructions", bytes(instructions)],
  ["MCP total, loaded every session", mcpAlways],
  ["Skill description (always loaded)", skillAlways],
  ["Skill body (loaded when used)", bytes(body)],
  ["CLI help for get_app_state, click, type_text (on demand)", typical],
  ["Skill + CLI total on a task that uses it", skillUsed],
];
for (const [label, n] of rows) console.log(`${label.padEnd(58)} ${String(n).padStart(7)} bytes  ~${String(tokens(n)).padStart(5)} tokens`);
console.log(`Tools: ${tools.length}. Tokens are bytes/4, an estimate.`);
