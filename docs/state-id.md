# State ids

A state id tells the runtime which view of an app the caller was looking at when it chose an action. If the app was captured again since, the action is refused before anything is sent. This stops a click on an element index that now means something else.

The same contract holds on macOS, Linux and Windows.

## Where the id appears

- Every `get_app_state` result that read the accessibility tree has one.
- Every action result that includes a fresh state has one.
- It is a short random hex string. It carries no meaning.
- It is returned in two places: a text item `State-ID: <id>` after the state text, and a `state_id` field on the tool result.

A `get_app_state` call with `include_ax=false` returns no id. That call reads no accessibility tree, so there are no element indexes to protect.

## Which tools accept it

`state_id` is an optional string argument on these tools:

- `click`
- `perform_secondary_action`
- `scroll`
- `drag`
- `type_text`
- `press_key`
- `set_value`
- `select_text` (macOS only, because only macOS has the tool)

The read tools `list_apps`, `get_app_state` and `query` do not take it.

If you leave it out, the action runs as before. The check is opt-in.

## The stale_state error

When `state_id` is given and it is not the id of the latest captured state for that app, the tool returns an error that starts with `stale_state:`. The check runs first. No click, key or write has been sent.

The fix is to call `get_app_state`, read the new state, and retry with the new id.

If `state_id` is not a string, the tool returns an argument error instead.

## What invalidates an id

- Any new capture of the same app. That includes a later `get_app_state` and the state returned by an action.
- `get_app_state` with `include_ax=false`. It drops the saved state for the app, so every earlier id is stale and old element indexes no longer work.
- An app that has no saved state. This includes an id from another run of the server.

The runtime keeps one saved state per app. The app can be named by name, bundle id or process id. These names share the same saved state.

An action that returns a fresh state also replaces the id. Use the id from that result for the next action.

## Read-back off

`ULTRATERM_COMPUTER_USE_ACTION_READ_BACK=0` makes macOS and Linux actions return `ok` instead of a new state. No new capture happens, so there is no new id. The id from the last `get_app_state` stays valid until something captures the app again.

The Windows runtime has no read-back switch. Its actions always return a state with a new id.

## Example

`get_app_state` returns the id:

```json
{
  "content": [
    { "type": "text", "text": "App=com.example.Notes (pid 412)\n..." },
    { "type": "text", "text": "State-ID: 3f9a1c07b2d4" }
  ],
  "isError": false,
  "state_id": "3f9a1c07b2d4"
}
```

An action that passes it:

```json
{ "app": "Notes", "element_index": "7", "state_id": "3f9a1c07b2d4" }
```

If the app was captured again in between, the answer is an error:

```json
{
  "content": [
    { "type": "text", "text": "stale_state: state_id '3f9a1c07b2d4' is not the latest captured state for 'Notes'. Nothing was sent. Call get_app_state and retry with the new state_id." }
  ],
  "isError": true
}
```

The wording of the message differs a little between platforms. The `stale_state` prefix is the same.

See also [background operation](background-operation.md).
