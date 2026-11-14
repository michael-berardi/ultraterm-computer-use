# UltraTerm Computer Use Installation

Read this reference when the user asks to install, verify, repair, or explain UltraTerm Computer Use setup.

## Platform Requirements

The macOS runtime requires macOS 14.0 or later. Windows and Linux use their own platform runtimes and are not subject to this macOS minimum.

On macOS, verify the system version before attempting to run the CLI:

```sh
sw_vers -productVersion
```

On macOS versions earlier than 14.0, npm installation may succeed but the bundled binary cannot launch. `ultraterm-computer-use doctor` and changes to Accessibility or Screen Recording permissions cannot fix this binary incompatibility.

## Install The CLI

Use npm:

```sh
npm install -g ultraterm-computer-use
```

Verify:

```sh
ultraterm-computer-use --help
ultraterm-computer-use doctor
ultraterm-computer-use call list_apps
```

If the package is already installed and the user asks to update it:

```sh
npm update -g ultraterm-computer-use
```

## macOS Permissions

On supported macOS versions, Accessibility and Screen Recording permissions are required before real app state and actions can work.

Run:

```sh
ultraterm-computer-use doctor
```

If permissions are missing, the onboarding UI opens. Ask the user to grant the requested permissions in System Settings. Do not try to bypass TCC prompts or silently manipulate protected settings.

Windows and Linux do not use this macOS onboarding step, but they still need a logged-in desktop session.

## Install This Skill (the default route)

The skill tells the agent to drive the CLI; it loads no tool schemas. Install it for Codex:

```sh
npx skills add your-org/ultraterm-computer-use -g -a codex --skill ultraterm-computer-use -y
npx skills ls -g -a codex | grep 'ultraterm-computer-use'
```

Install the skill for Claude Code:

```sh
npx skills add your-org/ultraterm-computer-use -g -a claude-code --skill ultraterm-computer-use -y
```

Update an existing global skill install:

```sh
npx skills update ultraterm-computer-use -g -y
npx skills upgrade ultraterm-computer-use -g -y
```

## Verification

After the CLI and skill are installed:

```sh
ultraterm-computer-use call list_apps
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
```

If this fails, read [troubleshooting.md](troubleshooting.md).

## Optional: install the MCP server into an agent config

The skill and CLI are the default route and need no MCP entry. Use these only for a host that can run MCP tools but not shell commands. The built-in installers:

```sh
ultraterm-computer-use install-codex-mcp
ultraterm-computer-use install-claude-mcp
ultraterm-computer-use install-gemini-mcp
ultraterm-computer-use install-gemini-mcp --scope user
ultraterm-computer-use install-opencode-mcp
```

Codex App can also use the plugin installer:

```sh
ultraterm-computer-use install-codex-plugin
```

Install into a DSH profile:

```sh
ultraterm-computer-use install-dsh-mcp

# from a source checkout
./scripts/install-dsh-mcp.sh
```

DSH profiles are composed from patch layers, so the installer writes a delimited
block into `<dsh-home>/profiles/<profile>/cordis.patch.yml` (default profile
`web`, default home `~/.dsh`). The block is replaced in place on every run, so
re-running is idempotent and the rest of the file is untouched. Before writing,
the installer performs an MCP `initialize` plus `tools/list` exchange and
requires the UltraTerm Computer Use server identity and a non-empty, valid tool
catalog. It deliberately does not pin a tool count, so compatible releases
can add or reshape tools. An unrelated or broken executable therefore fails
without changing the profile.

This is a compatibility integration through DSH's generic MCP client. It does
not register a first-class DSH computer-use provider or reserve DSH's exclusive
computer-use provider slot. Do not enable another desktop provider in the same
profile unless you deliberately want both independent tool sets to operate the
same desktop.

It also installs two things a DSH host needs beyond the MCP entry:

- **The turn-boundary hook.** UltraTerm Computer Use hides its software cursor only at
  a turn boundary, signalled by the MCP `notifications/turn-ended` notification.
  `dsh-mcp-client` never sends that notification, so without the hook the cursor
  stays on screen after the first action of any session or subagent. The
  installer writes `<dsh-home>/ocu-hooks.json` and maps DSH's Stop point onto
  `ultraterm-computer-use turn-ended`. Pass `--no-hook` to skip both.
- **Editing the hook later.** DSH's live patch reload only re-applies a row whose
  configuration actually changed, so editing `ocu-hooks.json` on its own leaves
  the running plugin holding its previous command. Change the patch row too (for
  example `defaultTimeoutMs`) to force a re-apply, or restart DSH.
- **The skill.** Copied to `<dsh-home>/skills/ultraterm-computer-use`, which DSH scans
  as a user-level skill root, so every new conversation can see it. Pass
  `--no-skill` to skip. An existing skill directory is never overwritten
  silently: when it differs from this checkout the installer leaves it in place
  and says so, and `--force-skill` replaces it while keeping a timestamped
  backup.

Options: `--profile <name>`, `--dsh-home <dir>`, `--command <path>`, `--no-hook`,
`--no-skill`, `--force-skill`. `--command` must be an absolute executable path.
DSH can resolve a bare PATH command, but an absolute path remains stable when a
GUI or background launch receives a different PATH. When the option is omitted,
the installer resolves the current PATH shim and common app/npm locations to an
absolute path, then fails with guidance if it finds nothing. Explicit DSH
installation treats MCP startup failure as a profile activation error rather
than silently starting without the requested tools.

For any other MCP client, add a stdio server manually:

```json
{
  "mcpServers": {
    "ultraterm-computer-use": {
      "command": "ultraterm-computer-use",
      "args": ["mcp"]
    }
  }
}
```
