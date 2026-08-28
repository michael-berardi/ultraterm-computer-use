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

## Install Into Agent MCP Configs

Use the built-in installers when they match the user's agent:

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

For any other MCP client, add a stdio server manually:

```json
{
  "mcpServers": {
    "ultraterm-computer-use": {
      "command": "overseer",
      "args": ["computer-use", "mcp"]
    }
  }
}
```

## Install This Skill

Install the skill for Codex:

```sh
npx skills add michael-berardi/ultraterm-computer-use -g -a codex --skill ultraterm-computer-use -y
npx skills ls -g -a codex | rg 'ultraterm-computer-use'
```

Install the skill for Claude Code:

```sh
npx skills add michael-berardi/ultraterm-computer-use -g -a claude-code --skill ultraterm-computer-use -y
```

Update an existing global skill install:

```sh
npx skills update ultraterm-computer-use -g -y
npx skills upgrade ultraterm-computer-use -g -y
```

## Verification

After CLI and MCP setup:

```sh
ultraterm-computer-use call list_apps
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
```

If this fails, read [troubleshooting.md](troubleshooting.md).
