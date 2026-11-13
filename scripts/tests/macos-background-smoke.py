#!/usr/bin/env python3
"""Drive Calculator through the native MCP server and prove it stays in the background.

Usage: python3 scripts/tests/macos-background-smoke.py /path/to/UltraTermComputerUse

Needs macOS with Accessibility and Screen Recording granted to the app under test. It launches
Calculator (and quits it afterwards when it was not already running), and checks that the
frontmost app never changes, that a stale state_id is refused before anything is sent, and that
a hidden app is reported instead of being brought forward.
"""

import json
import re
import subprocess
import sys
import time

FRONT = 'tell application "System Events" to get unix id of first process whose frontmost is true'


def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20).stdout.strip()


class MCP:
    def __init__(self, native, env=None):
        import os
        self.process = subprocess.Popen([native, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                        env={**os.environ, **(env or {})})
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                    "clientInfo": {"name": "background-smoke", "version": "1"}})

    def request(self, method, params):
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())["result"]

    def call(self, tool, **arguments):
        return self.request("tools/call", {"name": tool, "arguments": arguments})

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def text(result):
    return "\n".join(item.get("text", "") for item in result["content"] if item["type"] == "text")


def index_of(result, label):
    match = re.search(r"^\s*(\d+) button " + re.escape(label) + r"\b", text(result), re.M)
    assert match, "no button %r in:\n%s" % (label, text(result))
    return match.group(1)


def display(result):
    match = re.search(r"Edit field (.*)", text(result))
    assert match, text(result)
    return match.group(1).replace(",", "").strip()


def main(native):
    was_running = subprocess.run(["pgrep", "-x", "Calculator"], capture_output=True).returncode == 0
    front_before = osascript(FRONT)
    client = MCP(native)
    try:
        started = time.monotonic()
        state = client.call("get_app_state", app="Calculator", include_screenshot=False)
        assert not state.get("isError"), state
        assert re.fullmatch(r"[0-9a-f]{12}", state.get("state_id", "")), state.get("state_id")
        assert "State-ID: " + state["state_id"] in text(state)

        steps = 0
        for label in ("All Clear", "1", "2", "Multiply", "3", "4", "Equals"):
            # "All Clear" reads "Clear" once something was entered.
            try:
                index = index_of(state, label)
            except AssertionError:
                if label != "All Clear":
                    raise
                index = index_of(state, "Clear")
            previous = state["state_id"]
            state = client.call("click", app="Calculator", element_index=index, state_id=previous)
            assert not state.get("isError"), text(state)
            assert state["state_id"] != previous, "an action result must carry a new state_id"
            steps += 1
        elapsed = time.monotonic() - started
        assert display(state) == "408", display(state)
        print("Calculator: 12 x 34 = 408 in %d clicks, %.2f s, every click carried its state_id." % (steps, elapsed))

        # A state_id from before the last capture is stale: refused, and the display is untouched.
        stale = client.call("click", app="Calculator", element_index=index_of(state, "9"), state_id=previous)
        assert stale.get("isError") and text(stale).startswith("stale_state: "), stale
        assert display(client.call("get_app_state", app="Calculator", include_screenshot=False)) == "408"
        print("Stale state_id: refused before anything was sent.")

        assert osascript(FRONT) == front_before, "the frontmost app changed while Calculator was driven"
        print("Foreground: the frontmost app never changed.")

        # A hidden app is reported, not brought forward.
        osascript('tell application "System Events" to set visible of process "Calculator" to false')
        time.sleep(0.6)
        hidden = client.call("get_app_state", app="Calculator", include_screenshot=False)
        still_hidden = osascript('tell application "System Events" to get visible of process "Calculator"')
        if hidden.get("isError"):
            assert "ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1" in text(hidden), text(hidden)
            print("Hidden app: refused with the named switch.")
        else:
            print("Hidden app: readable in the background without being shown.")
        assert still_hidden == "false", "a hidden app was unhidden without the switch"
        assert osascript(FRONT) == front_before, "the frontmost app changed for a hidden app"
        print("Hidden app: left hidden; the frontmost app never changed.")
    finally:
        client.close()
        if was_running:
            osascript('tell application "System Events" to set visible of process "Calculator" to true')
        else:
            osascript('tell application "Calculator" to quit')
    print("macOS background smoke passed.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.platform != "darwin":
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
