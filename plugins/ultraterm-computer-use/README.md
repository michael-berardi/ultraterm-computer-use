# UltraTerm Computer Use plugin

The plugin installs the `ultraterm-computer-use` skill (`skills/ultraterm-computer-use`). The skill tells the agent to drive the `ultraterm-computer-use` CLI, so the plugin registers no MCP server and no tool schemas are loaded into the agent's context.

`skills/ultraterm-computer-use` is a copy of the repository's `skills/ultraterm-computer-use`; `test/plugin-skill.test.mjs` fails when they differ.

## Optional: MCP server

For a host that cannot run shell commands, or for read-then-act flows on Linux and Windows, `optional/mcp.json` holds the opt-in entry: the code-first JavaScript adapter, which lists only `js` and `js_reset`. To turn it on, add this line to `.codex-plugin/plugin.json` and restart the host:

```json
"mcpServers": "./optional/mcp.json",
```

The plain stdio server (`ultraterm-computer-use mcp`) is configured separately; see the repository README.
