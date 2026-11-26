# Updates

<!-- update-contract: v1 -->

UltraTerm Computer Use tells you when a newer stable release exists, and updating is one command.
Automatic installs are off unless you turn them on.

## Commands

```bash
ultraterm-computer-use update               # current → new and the release notes, then install after verification
ultraterm-computer-use update --check       # report only: exit 0 current, 10 update available, 1 check failed
ultraterm-computer-use update --skip        # no notice for this version; a newer one notifies again
ultraterm-computer-use update --auto on     # install future updates automatically (off by default)
ultraterm-computer-use update --auto off
ultraterm-computer-use update --auto status
ultraterm-computer-use update --rollback    # go back to the previous release (install.sh installs)
```

In a terminal, `update` asks `Install <new> now? [Y/n]`. After the first successful install it asks once
`Install future updates automatically? [y/N]` and remembers the answer. Without a terminal it installs
without questions: running the command is the consent. A failed check prints its cause and exits 1.

## The notice

After a command finishes in a terminal, at most once a day per version, on stderr:

```text
ultraterm-computer-use 0.12.0 available (you have 0.11.0) · run: ultraterm-computer-use update
turn on automatic updates: ultraterm-computer-use update --auto on · skip: ultraterm-computer-use update --skip
```

There is no notice, and no check, when stdout or stderr is not a terminal, when `CI` is set, under agent
hosts (Claude Code, Codex, Gemini CLI), with `--json`, or after `mcp` (the MCP server never prints it).
To turn checks off:

- for one shell: `ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK=1`
- to keep them off: `ultraterm-computer-use config set updates.check false` (signed macOS app: add
  `"updates": {"check": false}` to `~/.config/ultraterm-computer-use/config.json`)

## The check

- One anonymous GET of `https://api.github.com/repos/<owner>/<repo>/releases/latest`, for the repository
  named in the package metadata, with the User-Agent `ultraterm-computer-use-update-check`. It carries no
  version, identifier, machine or usage data.
- At most once every 24 hours, in a detached background process limited to 4 seconds, so no command waits
  for it. The notice uses the last result, so it shows on a later command.
- Only strictly newer stable `x.y.z` releases count. Drafts, prereleases and unparseable tags never do.
- A failure is recorded with its cause, never printed after other commands, and not retried until the next
  day. `update --check` shows the current result.

## How each install updates

| Installed with | `update` | `--auto on` | `--rollback` |
| --- | --- | --- | --- |
| `install.sh` or `install.ps1` | Downloads that release's installer, checks it against the release `SHA256SUMS`, and runs it pinned to the new version. The installer checks the npm tarball against `SHA256SUMS` before it changes anything. | yes | `install.sh` installs |
| `npm install --global <tgz>` | Downloads the release tarball, checks it against `SHA256SUMS`, and runs `npm install --global` on that file. | yes | no |
| Signed macOS installer | Downloads that release's `install-ultraterm-computer-use.sh`, checks it against `SHA256SUMS`, and runs it. It verifies the package checksum, Developer ID team, notarization and designated requirement, then asks for an administrator password. | no: the install needs an administrator password | no |
| Source checkout | Nothing; use `git pull`. | no | no |

New files apply the next time the tool starts. A running command or MCP server is never changed.

## Automatic updates

With `update --auto on`, or "y" to the one-time question, the daily background check installs a newer
release at low priority and writes the installer's output to `auto-update.log`. If that install fails, the
current version keeps working, the cause is recorded, the notice comes back, and that version is not
retried automatically.

## Files

Update state lives in one folder:

- macOS: `~/Library/Caches/ultraterm-computer-use`
- Linux: `$XDG_CACHE_HOME/ultraterm-computer-use` (default `~/.cache/ultraterm-computer-use`)
- Windows: `%LOCALAPPDATA%\ultraterm-computer-use\Cache`

`update-state.json` is owner-only and written atomically. It holds the last check time, result or failure
cause, the skipped version, when the notice was last shown and the automatic-install choice.
`auto-update.log` exists only after an automatic install and is kept under 256 KB.

Downloads go to a temporary folder that is removed on success and on failure. `install.sh` keeps the
release it replaced as the one rollback copy; the new version removes it after its first successful run, or
7 days after the update. To uninstall, also delete the folder above (the macOS
`ultraterm-computer-use uninstall` does this).

For tests, `ULTRATERM_COMPUTER_USE_UPDATE_API` points the npm launcher's check at another URL and
`UTCU_RELEASE_BASE` points downloads at another release folder.
