import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "worktape test"
let view = NSView()
view.wantsLayer = true
window.contentView = view

let animation = CABasicAnimation(keyPath: "backgroundColor")
animation.fromValue = NSColor.systemIndigo.cgColor
animation.toValue = NSColor.systemTeal.cgColor
animation.duration = 1
animation.autoreverses = true
animation.repeatCount = .infinity
view.layer?.add(animation, forKey: nil)

window.makeKeyAndOrderFront(nil)
application.activate()
application.run()
