import AppKit
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func flatten(_ element: AXUIElement, depth: Int = 0) -> [(AXUIElement, Int)] {
    guard depth < 30 else { return [] }
    let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [(element, depth)] + children.prefix(500).flatMap { flatten($0, depth: depth + 1) }
}
func describe(_ element: AXUIElement) -> String {
    [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]
        .compactMap { key in attribute(element, key).map { "\(key)=\($0)" } }.joined(separator: " | ")
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("Usage: swift scripts/native-qa.swift tree | click <index-or-label> | set <index> <value> | key <key> [command,shift,option] | type <text> | capture <path.png> | resize <width> <height>")
    exit(0)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Native QA needs Accessibility permission for the invoking terminal.\n".utf8)); exit(1)
}
let expectedBundle = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/Arpeggio.app").resolvingSymlinksInPath()
let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "tn.ashref.arpeggio").filter { $0.bundleURL?.resolvingSymlinksInPath() == expectedBundle }
guard candidates.count == 1, let application = candidates.first else {
    FileHandle.standardError.write(Data("Launch Arpeggio.app first.\n".utf8)); exit(1)
}
let app = AXUIElementCreateApplication(application.processIdentifier)
guard let source = CGEventSource(stateID: .privateState) else { exit(1) }
func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    for pressed in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed) else { continue }
        event.flags = flags
        if let text {
            Array(text.utf16).withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base) }
            }
        }
        event.postToPid(application.processIdentifier)
    }
}
func typeText(_ text: String) { for character in text { postKey(0, text: String(character)); Thread.sleep(forTimeInterval: 0.01) } }
let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
let nodes = windows.flatMap { flatten($0) } + flatten(app).filter {
    guard attribute($0.0, kAXRoleAttribute) as? String == kAXMenuItemRole else { return false }
    return attribute($0.0, kAXIdentifierAttribute) as? String == "menuAction:" ||
        ["Quit Arpeggio", "Close", "Connect…", "Browse User…"].contains(attribute($0.0, kAXTitleAttribute) as? String ?? "")
}
switch command {
case "tree":
    for (index, node) in nodes.enumerated() { print("\(index) " + String(repeating: " ", count: node.1) + describe(node.0)) }
case "click":
    guard arguments.count >= 2 else { exit(64) }
    let requested = arguments[1]
    let element: AXUIElement?
    if let index = Int(requested), nodes.indices.contains(index) { element = nodes[index].0 }
    else { element = nodes.first { node in
        [kAXButtonRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole].contains(attribute(node.0, kAXRoleAttribute) as? String ?? "") &&
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { attribute(node.0, $0) as? String == requested }
    }?.0 }
    guard let element else { print("No matching control: \(requested)"); exit(1) }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print("AXPress: \(result.rawValue)"); if result != .success { exit(1) }
case "set":
    guard arguments.count >= 3, let index = Int(arguments[1]), nodes.indices.contains(index) else { exit(64) }
    let result = AXUIElementSetAttributeValue(nodes[index].0, kAXValueAttribute as CFString, arguments[2] as CFString)
    print("AXSetValue: \(result.rawValue)"); if result != .success { exit(1) }
case "focus":
    guard arguments.count >= 2, let index = Int(arguments[1]), nodes.indices.contains(index) else { exit(64) }
    let element = nodes[index].0
    let result: AXError
    if attribute(element, kAXRoleAttribute) as? String == kAXWindowRole { result = AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    else { result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    print("AXFocus: \(result.rawValue)"); if result != .success { exit(1) }
case "close":
    guard arguments.count >= 2, let window = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == arguments[1] }),
          let value = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { print("No matching closable window."); exit(1) }
    let button = unsafeBitCast(value, to: AXUIElement.self)
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    print("AXClose: \(result.rawValue)"); if result != .success { exit(1) }
case "select":
    guard arguments.count >= 2 else { exit(64) }
    let element: AXUIElement?
    if let index = Int(arguments[1]), nodes.indices.contains(index) { element = nodes[index].0 }
    else {
        element = nodes.first { node in
            attribute(node.0, kAXRoleAttribute) as? String == kAXRowRole &&
            flatten(node.0).contains { attribute($0.0, kAXValueAttribute) as? String == arguments[1] }
        }?.0
    }
    guard let element else { print("No matching row."); exit(1) }
    let result = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    print("AXSelect: \(result.rawValue)"); if result != .success { exit(1) }
case "fill":
    guard arguments.count >= 3 else { exit(64) }
    let index: Int?
    if let numeric = Int(arguments[1]) { index = numeric }
    else {
        index = nodes.indices.first { position in
            position > 0 && attribute(nodes[position].0, kAXRoleAttribute) as? String == kAXTextFieldRole &&
            attribute(nodes[position - 1].0, kAXValueAttribute) as? String == arguments[1]
        }
    }
    guard let index, nodes.indices.contains(index) else { print("Text field not found: \(arguments[1]). Open its window first."); exit(1) }
    let focus = AXUIElementSetAttributeValue(nodes[index].0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focus == .success else { print("Text field focus failed: \(focus.rawValue)"); exit(1) }
    for _ in 0..<20 {
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFEqual(focused, nodes[index].0) { break }
        Thread.sleep(forTimeInterval: 0.025)
    }
    guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFEqual(focused, nodes[index].0) else { print("The app did not focus the requested field."); exit(1) }
    postKey(0, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.05)
    typeText(arguments[2]); Thread.sleep(forTimeInterval: 0.1)
    let value = attribute(nodes[index].0, kAXValueAttribute) as? String
    guard value == arguments[2] else { print("Typed input was not accepted by this control."); exit(1) }
    postKey(48)
case "key":
    let codes: [String: CGKeyCode] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
                                   "k": 40, "f": 3, ",": 43, "n": 45, "b": 11, "w": 13, "q": 12, "return": 36, "tab": 48,
                                   "escape": 53, "space": 49, "down": 125, "up": 126, "a": 0]
    guard arguments.count >= 2, let code = codes[arguments[1]] else { exit(64) }
    let modifiers = arguments.count > 2 ? arguments[2] : ""
    var flags: CGEventFlags = []
    if modifiers.contains("command") { flags.insert(.maskCommand) }
    if modifiers.contains("shift") { flags.insert(.maskShift) }
    if modifiers.contains("option") { flags.insert(.maskAlternate) }
    postKey(code, flags: flags)
case "type":
    guard arguments.count >= 2 else { exit(64) }
    typeText(arguments[1])
case "capture":
    guard arguments.count >= 2 else { exit(64) }
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let title = arguments.count > 2 ? arguments[2] : nil
    guard let window = info.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 0 && (title == nil || $0[kCGWindowName as String] as? String == title)
    }),
          let id = window[kCGWindowNumber as String] as? UInt32 else { print("No visible app window."); exit(1) }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(id), arguments[1]]
    try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
case "resize":
    guard arguments.count >= 3, let width = Double(arguments[1]), let height = Double(arguments[2]), let window = windows.first else { exit(64) }
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size) else { exit(1) }
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    print("AXResize: \(result.rawValue)"); if result != .success { exit(1) }
default: print("Unknown command: \(command)"); exit(64)
}
