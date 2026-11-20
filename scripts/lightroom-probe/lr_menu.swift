// Presses Lightroom Classic's "Argent Probe: run pending jobs" through accessibility, on the one process it is given.
// It presses that item and nothing else: no menu is opened, no key is sent, the pointer does not move.
// `jobs.py run` compiles and calls it.
//
//   lr_menu PID items     every Plug-in Extras item under File and Library, and whether it is enabled
//   lr_menu PID press     AXPress on the item: Library's if that menu is there, else File's
//   lr_menu PID windows   each on-screen window from the window server: id, alpha, x,y, width x height and name, for
//                         spotting a dialog. Not from accessibility: after a while Lightroom answers AXWindows with its
//                         application element, once per window, so a dialog would not show there.
//   lr_menu PID activate  makes the app frontmost. In the background Lightroom's menu bar is a stub with no
//                         Plug-in Extras, so the item exists only while Lightroom is in front.
import ApplicationServices
import CoreGraphics
import Foundation

let ITEM = "Argent Probe: run pending jobs"

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: lr_menu PID items|press|windows|activate\n".data(using: .utf8)!)
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("this binary is not trusted for accessibility\n".data(using: .utf8)!)
    exit(3)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func str(_ e: AXUIElement, _ name: String) -> String {
    guard let v = attr(e, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { str(e, kAXTitleAttribute).trimmingCharacters(in: .whitespaces) }
func enabled(_ e: AXUIElement) -> Bool { (attr(e, kAXEnabledAttribute) as? Bool) ?? false }

/// The items of one top menu's Plug-in Extras submenu, read without opening anything.
func extras(_ menuTitle: String) -> [AXUIElement]? {
    guard let bar = attr(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
    guard let top = children(bar as! AXUIElement).first(where: { title($0) == menuTitle }),
          let menu = children(top).first,
          let extrasItem = children(menu).first(where: { title($0) == "Plug-in Extras" }),
          let submenu = children(extrasItem).first else { return nil }
    return children(submenu)
}

switch args[2] {
case "items":
    for menu in ["Library", "File"] {
        guard let items = extras(menu) else { print("\(menu): no Plug-in Extras"); continue }
        for item in items where !title(item).isEmpty {
            print("\(menu) > Plug-in Extras > \(title(item))\(enabled(item) ? "" : " [disabled]")")
        }
    }
case "press":
    for menu in ["Library", "File"] {
        guard let item = extras(menu)?.first(where: { title($0) == ITEM }) else { continue }
        guard enabled(item) else { print("\(menu) > Plug-in Extras > \(ITEM) is disabled"); exit(1) }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print("pressed \(menu) > Plug-in Extras > \(ITEM): \(result == .success ? "ok" : "AXError \(result.rawValue)")")
        exit(result == .success ? 0 : 1)
    }
    print("no \(ITEM) under Library or File > Plug-in Extras")
    exit(1)
case "activate":
    let result = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    print("frontmost \(pid): \(result == .success ? "ok" : "AXError \(result.rawValue)")")
    exit(result == .success ? 0 : 1)
case "windows":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let n = { (k: String) in (b[k] as? NSNumber)?.intValue ?? 0 }
        let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
        print("\(w[kCGWindowNumber as String] ?? 0)\t\(alpha)\t\(n("X")),\(n("Y"))\t\(n("Width"))x\(n("Height"))\t\(w[kCGWindowName as String] ?? "")")
    }
default:
    FileHandle.standardError.write("unknown command \(args[2])\n".data(using: .utf8)!)
    exit(2)
}
