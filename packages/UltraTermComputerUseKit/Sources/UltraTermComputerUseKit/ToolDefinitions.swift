import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    public static var all: [ToolDefinition] {
        configured(virtualDisplayEnabled: VirtualDisplayConfig.current.enabled)
    }

    static func configured(virtualDisplayEnabled: Bool) -> [ToolDefinition] {
        guard !virtualDisplayEnabled else { return definitions }
        return definitions.map { tool in
            guard tool.name == "get_app_state" else { return tool }
            var schema = tool.inputSchema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties.removeValue(forKey: "window_placement")
            schema["properties"] = properties
            return ToolDefinition(name: tool.name, description: tool.description, annotations: tool.annotations, inputSchema: schema)
        }
    }

    private static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index or pixel coordinates from screenshot. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "element_index": stringProperty(description: "Element index to click"),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates"),
                    "click_count": positiveIntegerProperty(description: "Number of clicks. Defaults to 1"),
                    "mouse_button": stringProperty(
                        description: "Mouse button to click. Defaults to left.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "click_method": stringProperty(
                        description: "Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. app_post sends a public event directly to the target app. sky_click uses the macOS SkyLight background window path. Global may move the system pointer and requires ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1.",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag from one point to another using pixel coordinates. By default mouse events are posted directly to the target app and the system pointer does not move; that path cannot drive window-server drag sessions such as window moves, text selection, or Finder drag-and-drop. Those require ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment, which may move the real pointer. The result reports which path was used. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "query",
            description: "Targeted accessibility lookup: find controls in the app's current window using bounded AX traversal, with no full snapshot and no screenshot. Returns matches with truncated, stop_reason, visited_nodes and window_id metadata. Each match has a session-local `index` usable by the element actions (click, set_value, scroll, perform_secondary_action). Requires text and/or role. Only queries already-running apps; indexes expire after 120 seconds. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Match text in the control's title, description or value (up to 1000 UTF-16 code units). Case-insensitive substring unless exact is true. Long fields are bounded and reported as truncated."),
                    "role": stringProperty(description: "Match this accessibility role (the AX prefix is optional, e.g. button or AXButton)"),
                    "exact": [
                        "type": "boolean",
                        "description": "Require a complete text match instead of a substring. Defaults to false. No substring retry.",
                    ],
                    "limit": positiveIntegerProperty(description: "Maximum matches to return. Defaults to 20; capped at 100."),
                    "max_nodes": positiveIntegerProperty(description: "Node/queue cap for AX traversal. Defaults to 500; capped at 5000. Search has a 2-second cooperative deadline."),
                    "window_id": positiveIntegerProperty(description: "Search this specific window (CGWindowID, 1–4294967295) instead of the app's current window."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "include_ax": ["type": "boolean", "default": true, "description": "Include accessibility tree, focus and selection. False skips collection and invalidates previous element indexes; read AX again before element actions."],
                    "include_screenshot": ["type": "boolean", "default": true, "description": "Capture and return a screenshot. False skips capture and encoding; screenshot-coordinate actions require a fresh screenshot."],
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text_limit": textLimitProperty(description: "Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
                    "max_tree_nodes": positiveIntegerProperty(description: "Maximum accessibility tree nodes to render. Defaults to 1200."),
                    "max_tree_depth": positiveIntegerProperty(description: "Maximum accessibility tree depth to render. Defaults to 64."),
                    "window_placement": stringProperty(
                        description: "keep (default) leaves the window where it is. agent_display (macOS) parks the app's window on an invisible display owned by the agent so a covered or other-Space window renders, exposes its full tree and accepts input without touching the user's Space, focus or pointer; the window disappears from the user's desktop until restore or process exit. restore puts it back.",
                        enumValues: WindowPlacement.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "element_index": stringProperty(description: "Element identifier"),
                    "action": stringProperty(description: "Secondary accessibility action name"),
                ],
                required: ["app", "element_index", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0 key). This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "key": stringProperty(description: "Key or key combination to press"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "pages": numberProperty(description: "Number of pages to scroll. Fractional values are supported. Defaults to 1"),
                ],
                required: ["app", "element_index", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable accessibility element and verify the actual value. Text is compared exactly, including whitespace; an empty string clears it. Unverified writes return an error, even when full action read-back is disabled. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "element_index": stringProperty(description: "Element identifier"),
                    "value": stringProperty(description: "Value to assign"),
                ],
                required: ["app", "element_index", "value"]
            )
        ),
        ToolDefinition(
            name: "select_text",
            description: "Select text inside a text element, or place the text cursor before or after it. Provide text exactly as it appears in the accessibility tree, including any Markdown formatting. If the text is not unique, provide surrounding prefix or suffix text to disambiguate it. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "element_index": stringProperty(description: "Text element identifier"),
                    "text": stringProperty(description: "Target text as shown in the accessibility tree"),
                    "prefix": stringProperty(description: "Optional text immediately before the target, used to disambiguate repeated matches"),
                    "suffix": stringProperty(description: "Optional text immediately after the target, used to disambiguate repeated matches"),
                    "selection": stringProperty(
                        description: "Whether to select the text or place the cursor before or after it. Defaults to text.",
                        enumValues: TextSelectionMode.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app", "element_index", "text"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal text using keyboard input. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "state_id": stringProperty(description: stateIDArgumentDescription),
                    "text": stringProperty(description: "Literal text to type"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "text"]
            )
        ),
    ]
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func keyMethodProperty() -> [String: Any] {
    stringProperty(
        description: "Keyboard delivery: auto (default) or sky_key. sky_key posts authenticated keyboard events through the macOS SkyLight background-window path to the current target window without changing foreground focus. Requires a current on-screen target window from get_app_state.",
        enumValues: KeyMethod.allCases.map(\.rawValue)
    )
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "description": description,
    ]

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String) -> [String: Any] {
    [
        "type": "number",
        "description": description,
    ]
}

/// JSON payload for the `tools` CLI command: one tool's definition when
/// `name` is given, otherwise the full catalog.
public func ultraTermComputerUseToolsPayload(name: String?) throws -> Any {
    if let name {
        guard let definition = ToolDefinitions.all.first(where: { $0.name == name }) else {
            throw ComputerUseError.unsupportedTool(name)
        }
        return definition.asDictionary
    }

    return ToolDefinitions.all.map(\.asDictionary)
}

/// Human-readable listing for the `tools` CLI command.
public func ultraTermComputerUseToolsText(name: String?) throws -> String {
    if let name {
        guard let definition = ToolDefinitions.all.first(where: { $0.name == name }) else {
            throw ComputerUseError.unsupportedTool(name)
        }

        var lines = ["\(definition.name) — \(definition.description)"]
        let schema = definition.inputSchema
        let required = schema["required"] as? [String] ?? []
        let properties = schema["properties"] as? [String: Any] ?? [:]
        if !properties.isEmpty {
            lines.append("arguments:")
            for key in properties.keys.sorted() {
                let requiredMark = required.contains(key) ? " (required)" : ""
                lines.append("  \(key)\(requiredMark)")
            }
        }
        return lines.joined(separator: "\n")
    }

    return ToolDefinitions.all
        .map { "\($0.name) — \($0.description)" }
        .joined(separator: "\n")
}

/// Validates tool call arguments against the declared input schemas before
/// any tool executes. Used for CLI sequence preflight so an invalid later call
/// produces zero prior mutations.
///
/// Coercions intentionally mirror the dispatcher's runtime normalization:
/// numbers are accepted for number/integer properties, and `element_index`
/// accepts a string or a whole number.
public enum ToolSchemaValidator {
    public static func isKnownTool(_ name: String) -> Bool {
        ToolDefinitions.all.contains { $0.name == name }
    }

    /// Throws `ComputerUseError.unsupportedTool` for an unknown tool and
    /// `ComputerUseError.invalidArguments` for the first schema violation.
    public static func validate(tool: String, arguments: [String: Any]) throws {
        guard let definition = ToolDefinitions.all.first(where: { $0.name == tool }) else {
            throw ComputerUseError.unsupportedTool(tool)
        }

        let schema = definition.inputSchema
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let additionalPropertiesAllowed = schema["additionalProperties"] as? Bool ?? true

        for key in required {
            guard let value = arguments[key], !(value is NSNull) else {
                throw ComputerUseError.invalidArguments("missing required argument '\(key)' for tool '\(tool)'")
            }
        }

        for (key, value) in arguments {
            if value is NSNull {
                continue
            }

            guard let property = properties[key] as? [String: Any] else {
                if !additionalPropertiesAllowed {
                    throw ComputerUseError.invalidArguments("unknown argument '\(key)' for tool '\(tool)'")
                }
                continue
            }

            try validateValue(value, forKey: key, property: property, tool: tool)
        }
    }

    private static func validateValue(
        _ value: Any,
        forKey key: String,
        property: [String: Any],
        tool: String
    ) throws {
        if let anyOf = property["anyOf"] as? [[String: Any]] {
            var lastError: ComputerUseError?
            for option in anyOf {
                do {
                    try validateValue(value, forKey: key, property: option, tool: tool)
                    return
                } catch let error as ComputerUseError {
                    lastError = error
                }
            }
            throw lastError ?? ComputerUseError.invalidArguments("'\(key)' is invalid for tool '\(tool)'")
        }

        if let allowed = property["enum"] as? [String] {
            guard let string = value as? String, allowed.contains(string) else {
                throw ComputerUseError.invalidArguments(
                    "'\(key)' must be one of \(allowed.joined(separator: ", ")) for tool '\(tool)'"
                )
            }
            return
        }

        switch property["type"] as? String {
        case "string":
            if key == "element_index", normalizedElementIndexArgument(value) != nil {
                return
            }
            guard value is String else {
                throw ComputerUseError.invalidArguments("'\(key)' must be a string for tool '\(tool)'")
            }
        case "boolean":
            guard isBoolean(value) else {
                throw ComputerUseError.invalidArguments("'\(key)' must be a boolean for tool '\(tool)'")
            }
        case "integer":
            guard let integer = numericValue(value) else {
                throw ComputerUseError.invalidArguments("'\(key)' must be an integer for tool '\(tool)'")
            }
            guard integer.rounded(.towardZero) == integer else {
                throw ComputerUseError.invalidArguments("'\(key)' must be an integer for tool '\(tool)'")
            }
            if let minimum = property["minimum"] as? Double, integer < minimum {
                throw ComputerUseError.invalidArguments("'\(key)' must be >= \(Int(minimum)) for tool '\(tool)'")
            }
            if let minimum = property["minimum"] as? Int, integer < Double(minimum) {
                throw ComputerUseError.invalidArguments("'\(key)' must be >= \(minimum) for tool '\(tool)'")
            }
        case "number":
            guard numericValue(value) != nil else {
                throw ComputerUseError.invalidArguments("'\(key)' must be a number for tool '\(tool)'")
            }
        default:
            return
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        if value is Bool {
            return true
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        }
        return false
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return nil
            }
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let integer = value as? Int {
            return Double(integer)
        }
        return nil
    }
}
