// Presses a menu item of a running app through the Accessibility API:
//
//   menuclick <app name> <menu> <item>     e.g. menuclick PreviewMD PreviewMD "About PreviewMD"
//
// Not `osascript` + System Events: that needs an Apple Events grant the
// Cirrus Labs guest agent does not have, so it waits on a consent prompt
// nobody can click. The agent does have Accessibility, which is all this needs.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: menuclick <app name> <menu> <item>") }
let (appName, menuName, itemName) = (args[1], args[2], args[3])
guard AXIsProcessTrusted() else { fail("this process has no Accessibility grant") }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    fail("\(appName) is not running")
}
app.activate()

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    return value as? [AXUIElement] ?? []
}
func title(_ element: AXUIElement) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
    return value as? String ?? ""
}

let root = AXUIElementCreateApplication(app.processIdentifier)
var menuBar: CFTypeRef?
guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &menuBar) == .success,
      let bar = menuBar else { fail("\(appName) has no menu bar") }
guard let menu = children(bar as! AXUIElement).first(where: { title($0) == menuName }) else {
    fail("no \"\(menuName)\" menu")
}
let items = children(menu).flatMap(children)   // menu bar item → its menu → the items
guard let item = items.first(where: { title($0) == itemName }) else {
    fail("no \"\(itemName)\" in \(menuName): \(items.map(title).filter { !$0.isEmpty })")
}
let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
guard result == .success else { fail("pressing \"\(itemName)\" failed: AXError \(result.rawValue)") }
