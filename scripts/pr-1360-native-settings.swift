import AppKit
import ApplicationServices

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func poll<T>(_ description: String, timeout: TimeInterval = 15, _ check: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let result = check() { return result }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    throw CheckFailure("Timed out waiting for \(description)")
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func elements(in root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 32 else { return [root] }
    let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [root] + children.flatMap { elements(in: $0, depth: depth + 1) }
}

func named(_ element: AXUIElement, _ name: String) -> Bool {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].contains {
        string(element, $0).contains(name)
    }
}

func lookup(_ root: AXUIElement, id: String, role: String, label: String) -> AXUIElement? {
    let candidates = elements(in: root).filter { string($0, kAXRoleAttribute) == role }
    return candidates.first { string($0, "AXDOMIdentifier") == id || string($0, "AXIdentifier") == id }
        ?? candidates.first { named($0, label) }
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
          let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var bounds = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &bounds) else { return nil }
    return CGRect(origin: origin, size: bounds)
}

// wry's WKWebView refuses first mouse (accept_first_mouse defaults to false), so a
// click into a window that is not key only activates it and never reaches the DOM.
func isKeyAndFrontmost(_ app: AXUIElement, _ window: AXUIElement, _ pid: pid_t) -> Bool {
    var focusedPid: pid_t = 0
    guard let focusedApp = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
          CFGetTypeID(focusedApp) == AXUIElementGetTypeID(),
          AXUIElementGetPid(focusedApp as! AXUIElement, &focusedPid) == .success,
          focusedPid == pid,
          let focused = attribute(app, kAXFocusedWindowAttribute) else { return false }
    return CFEqual(focused, window)
}

func onScreenWindowOwners() -> String {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String else { return nil }
        return "\(owner) (layer \(window[kCGWindowLayer as String] as? Int ?? -1))"
    }.joined(separator: ", ")
}

func click(_ element: AXUIElement, _ label: String) throws {
    _ = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    Thread.sleep(forTimeInterval: 0.15)
    guard let rect = frame(element), !rect.isEmpty else {
        throw CheckFailure("No screen bounds for \(label)")
    }
    let point = CGPoint(x: rect.midX, y: rect.midY)
    guard CGDisplayBounds(CGMainDisplayID()).contains(point),
          let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        throw CheckFailure("Cannot click \(label) at \(point)")
    }
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    up.post(tap: .cghidEventTap)
    print("Clicked \(label) at \(point)")
    Thread.sleep(forTimeInterval: 0.2)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
        throw CheckFailure("Could not create keyboard event")
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
}

func screenshot(_ proof: URL, _ name: String) throws {
    let target = proof.appendingPathComponent(name + ".png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-t", "png", target.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0,
          let bitmap = NSImage(contentsOf: target),
          bitmap.size.width > 100, bitmap.size.height > 100 else {
        throw CheckFailure("No valid desktop screenshot at \(target.path)")
    }
    print("Captured \(name).png (\(bitmap.size))")
}

let remote = "OpenAI-compatible — remote, batch only (opt in)"
let whisper = "Whisper — broad language support, built-in"
let fields: [(id: String, label: String, key: String, value: String)] = [
    ("settings-transcription-base-url", "Remote transcription base URL", "openai_compatible_base_url", "https://transcription.example.invalid/v1"),
    ("settings-transcription-remote-model", "Remote model", "openai_compatible_model", "minutes-ci-model"),
    ("settings-transcription-key-env", "API key environment variable name", "openai_compatible_api_key_env", "MINUTES_CI_UNUSED_KEY"),
    ("settings-transcription-upload-limit", "Upload limit in bytes", "openai_compatible_max_upload_bytes", "13750000"),
]

func checkSettings() throws {
    guard CommandLine.arguments.count == 4,
          let pid = pid_t(CommandLine.arguments[1]) else {
        throw CheckFailure("Expected the installed app PID, evidence directory and isolated config path")
    }
    let proof = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let config = URL(fileURLWithPath: CommandLine.arguments[3])
    let running = try poll("the installed app to register with macOS") {
        NSRunningApplication(processIdentifier: pid)
    }
    let app = AXUIElementCreateApplication(pid)
    defer {
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
           let window = windows.first {
            let tree = elements(in: window).map { element in
                [kAXRoleAttribute, "AXDOMIdentifier", kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .map { string(element, $0) }.joined(separator: " | ")
            }.joined(separator: "\n")
            try? tree.write(to: proof.appendingPathComponent("accessibility-tree.log"), atomically: true, encoding: .utf8)
        }
    }

    let bundlePath = running.bundleURL?.path ?? ""
    guard bundlePath.hasSuffix("/Applications/Minutes Dev.app"),
          running.bundleIdentifier == "com.useminutes.desktop.dev" else {
        throw CheckFailure("Unexpected app bundle \(bundlePath)")
    }
    print("Testing \(bundlePath)")
    print("Native accessibility preflight \(AXIsProcessTrusted()), event posting \(CGPreflightPostEventAccess())")
    let window = try poll("the installed Minutes Dev window", timeout: 45) {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }
    _ = running.activate()
    _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

    func openTranscription() throws {
        do {
            let _: Bool = try poll("Minutes Dev frontmost with its window key") {
                isKeyAndFrontmost(app, window, pid) ? true : nil
            }
        } catch {
            throw CheckFailure("\(error); windows on screen: \(onScreenWindowOwners())")
        }
        let settings = try poll("Settings gear") {
            lookup(window, id: "btn-settings", role: kAXButtonRole, label: "⚙")
                ?? lookup(window, id: "btn-settings", role: kAXButtonRole, label: "Settings (")
        }
        try click(settings, "Settings")
        let tab = try poll("Transcription tab") {
            lookup(window, id: "tab-transcription", role: kAXRadioButtonRole, label: "Transcription")
                ?? lookup(window, id: "tab-transcription", role: kAXButtonRole, label: "Transcription")
        }
        try click(tab, "Transcription")
    }

    func engine(_ label: String) -> AXUIElement? {
        guard let control = lookup(window, id: "settings-transcription-engine", role: kAXPopUpButtonRole, label: label),
              named(control, label) else { return nil }
        return control
    }

    func configContains(_ setting: String, _ value: String) -> Bool {
        guard let body = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return body.split(separator: "\n").contains { line in
            let items = line.split(separator: "=", maxSplits: 1)
            guard items.count == 2, items[0].trimmingCharacters(in: .whitespaces) == setting else { return false }
            return items[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == value
        }
    }

    func selectEngine(_ menu: AXUIElement, label: String, arrow: CGKeyCode, count: Int) throws {
        try click(menu, "engine selector")
        if let option = elements(in: app).first(where: {
            string($0, kAXRoleAttribute) == kAXMenuItemRole && named($0, label)
        }), AXUIElementPerformAction(option, kAXPressAction as CFString) == .success {
            print("Selected \(label) using the native menu item")
        } else {
            for _ in 0..<count { try key(arrow) }
            try key(36)
            print("Selected \(label) using the engine menu keyboard navigation")
        }
    }

    func field(_ entry: (id: String, label: String, key: String, value: String)) -> AXUIElement? {
        lookup(window, id: entry.id, role: kAXTextFieldRole, label: entry.label)
            ?? lookup(window, id: entry.id, role: "AXIncrementor", label: entry.label)
    }

    try openTranscription()
    let localMenu = try poll("default Auto (Whisper) engine") { engine("Auto (Whisper)") }
    try screenshot(proof, "01-local-default")
    try selectEngine(localMenu, label: remote, arrow: 125, count: 2)
    let _: Bool = try poll("remote engine persisted and all four fields visible") {
        configContains("engine", "openai-compatible") && fields.allSatisfy { field($0) != nil } ? true : nil
    }

    for entry in fields {
        let input = try poll(entry.label) { field(entry) }
        try click(input, entry.label)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(entry.value, forType: .string) else {
            throw CheckFailure("Could not stage test input for \(entry.label)")
        }
        try key(0, flags: .maskCommand)
        try key(9, flags: .maskCommand)
        try key(48)
        let _: Bool = try poll("saved \(entry.label)") { configContains(entry.key, entry.value) ? true : nil }
        print("Persisted \(entry.label)")
    }
    try screenshot(proof, "02-remote-saved")

    let close = try poll("Settings Close button") {
        lookup(window, id: "btn-settings-close", role: kAXButtonRole, label: "Close")
    }
    try click(close, "Close Settings")
    let _: Bool = try poll("Settings closed") { engine(remote) == nil ? true : nil }
    try openTranscription()
    let _: Bool = try poll("all saved values shown after reopening Settings") {
        fields.allSatisfy { entry in
            guard let input = field(entry) else { return false }
            return string(input, kAXValueAttribute) == entry.value
                || (attribute(input, kAXValueAttribute) as? NSNumber)?.stringValue == entry.value
        } ? true : nil
    }
    print("All four saved fields reloaded after closing and reopening Settings")
    try screenshot(proof, "03-remote-reopened")

    let remoteMenu = try poll("persisted remote selection") { engine(remote) }
    try selectEngine(remoteMenu, label: whisper, arrow: 126, count: 1)
    let _: Bool = try poll("explicit Whisper selection persisted and remote fields hidden") {
        configContains("engine", "whisper") && engine(whisper) != nil && fields.allSatisfy { field($0) == nil } ? true : nil
    }
    print("Switched back to Whisper. Remote controls are hidden.")
    try screenshot(proof, "04-whisper-restored")
    print("PASS: native Settings engine selection, four retained fields, and local switch-back")
}

setvbuf(stdout, nil, _IOLBF, 0)
do {
    try checkSettings()
} catch {
    if CommandLine.arguments.count == 4 {
        try? screenshot(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), "failure")
    }
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
