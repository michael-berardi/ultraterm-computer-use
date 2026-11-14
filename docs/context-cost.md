# Context cost: skill and CLI against MCP

An agent that uses Computer Use through MCP has the server's tool schemas and instructions in its context for the whole session, used or not. An agent that uses the skill and the CLI has only the skill's one-paragraph description until the task needs it, then the skill body, then the help of the one or two tools it calls.

Measured with `node scripts/measure-context-cost.mjs` (it only runs `tools --json` and `help <tool>`, which are offline) on version 0.10.2, 11 tools (macOS runtime). Tokens are bytes divided by 4, an estimate; the byte counts are exact.

| What is loaded | When | Bytes | About tokens |
| --- | --- | ---: | ---: |
| MCP `tools/list` result | every session with the server | 12,598 | 3,150 |
| MCP `initialize` instructions | every session with the server | 2,440 | 610 |
| **MCP total** | **every session** | **15,038** | **3,760** |
| Skill description (front matter) | every session with the skill installed | 326 | 82 |
| Skill body (`SKILL.md`) | when the task uses Computer Use | 6,284 | 1,571 |
| `help get_app_state`, `help click`, `help type_text` | on demand, per tool used | 3,930 | 983 |
| **Skill and CLI total** | **a task that uses it** | **10,540** | **2,635** |

- A session that does not touch the desktop: 326 bytes against 15,038 (98% less).
- A task that does: 10,540 bytes against 15,038 (30% less), and only the tools it calls are described. The skill's references (`usage.md` and the others) are read only when the task needs them and are not counted.
- Output size is separate. `call` prints plain text by default and notes a screenshot instead of embedding base64; `--json` restores the envelope. This is not included in the table because it depends on the app.

The MCP server remains available (`ultraterm-computer-use mcp`) for hosts that cannot run shell commands.
