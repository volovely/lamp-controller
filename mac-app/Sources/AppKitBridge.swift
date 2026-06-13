// AppKitBridge.swift
// The ONLY file in this app that reaches AppKit via the ObjC runtime.
// Mac Catalyst cannot `import AppKit`, so NSApplication / NSStatusBar / NSMenu
// are reached through NSClassFromString + dlsym(objc_msgSend). Everything
// objc_msgSend-shaped lives here and nowhere else.

import Foundation
import Darwin
import ObjectiveC

enum AppKitBridge {
    /// objc_msgSend raw symbol (RTLD_DEFAULT == -2). Computed (not stored) to stay
    /// Sendable-safe under Swift 6; dlsym is a cheap table lookup.
    fileprivate static var msgSend: UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    }

    /// Flip the process to NSApplicationActivationPolicyAccessory (== 1):
    /// no Dock icon, no window required, and — critically — foreground-active
    /// enough for HomeKit writes to succeed.
    @MainActor
    static func setAccessoryActivationPolicy() {
        guard
            let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
            let sharedApp = appClass.value(forKey: "sharedApplication") as? NSObject,
            let sym = Self.msgSend
        else { return }
        typealias SetPolicyFn = @convention(c) (AnyObject, Selector, Int) -> Bool
        let fn = unsafeBitCast(sym, to: SetPolicyFn.self)
        _ = fn(sharedApp, NSSelectorFromString("setActivationPolicy:"), 1)
    }

    /// Mac Catalyst defaults to terminating the app when its last window closes,
    /// which would also tear down the menu-bar status item. Override the
    /// NSApplication delegate's `applicationShouldTerminateAfterLastWindowClosed:`
    /// to return NO, so the app keeps running headless in the menu bar after the
    /// Activity window is closed. Quit from the menu (exit(0)) is the way to exit.
    @MainActor
    static func preventTerminationOnLastWindowClose() {
        guard
            let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
            let sharedApp = appClass.value(forKey: "sharedApplication") as? NSObject,
            let delegate = sharedApp.value(forKey: "delegate") as? NSObject,
            let cls: AnyClass = object_getClass(delegate)
        else { return }
        let sel = NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:")
        // Block IMP signature is (self, sender) -> BOOL — no _cmd.
        let block: @convention(block) (AnyObject, AnyObject) -> ObjCBool = { _, _ in ObjCBool(false) }
        let imp = imp_implementationWithBlock(block)
        // class_replaceMethod adds the method if absent, replaces it if present.
        class_replaceMethod(cls, sel, imp, "c@:@")
    }
}

extension AppKitBridge {
    /// One menu row. A nil `handler` (or `isSeparator`) yields a disabled/inert
    /// item — NSMenu autoenable greys items with no target/action.
    struct Entry {
        var title: String
        var handler: (@MainActor () -> Void)?
        var isSeparator: Bool = false
        static func separator() -> Entry { Entry(title: "", handler: nil, isSeparator: true) }
    }

    /// @objc trampoline: NSMenuItem calls `fire`, we invoke the Swift closure.
    /// @MainActor because NSMenu callbacks always arrive on the main thread.
    @MainActor @objc final class ActionTarget: NSObject {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler; super.init() }
        @objc func fire() { handler() }
    }

    /// Live wrapper around an NSStatusItem created via the ObjC runtime.
    /// Must only be accessed on the main thread (all AppKit/status-bar work is main-thread).
    @MainActor final class StatusItem {
        private let item: AnyObject
        private var menu: AnyObject?
        private var targets: [ActionTarget] = []   // keep handlers alive

        // objc_msgSend casts — confined to this type.
        private typealias MsgObj = @convention(c) (AnyObject, Selector) -> AnyObject?
        private typealias MsgObjCGFloat = @convention(c) (AnyObject, Selector, CGFloat) -> AnyObject?
        private typealias MsgVoidObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        private typealias MsgItem =
            @convention(c) (AnyObject, Selector, AnyObject?, Selector, AnyObject?) -> AnyObject?

        /// Returns nil if the runtime classes/symbol are unavailable.
        init?(title: String) {
            guard
                let sym = AppKitBridge.msgSend,
                let barClass = NSClassFromString("NSStatusBar")
            else { return nil }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard let bar = msgObj(barClass, NSSelectorFromString("systemStatusBar")) else { return nil }
            let msgLen = unsafeBitCast(sym, to: MsgObjCGFloat.self)
            guard let item = msgLen(bar, NSSelectorFromString("statusItemWithLength:"), -1) else { return nil }
            self.item = item
            setButtonTitle(title)
        }

        func setButtonTitle(_ title: String) {
            guard let sym = AppKitBridge.msgSend else { return }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard let button = msgObj(item, NSSelectorFromString("button")) else { return }
            let setTitle = unsafeBitCast(sym, to: MsgVoidObj.self)
            setTitle(button, NSSelectorFromString("setTitle:"), title as AnyObject)
        }

        /// Replace the menu with a fresh one built from `entries`.
        func setMenu(_ entries: [Entry]) {
            guard let sym = AppKitBridge.msgSend, let menuClass = NSClassFromString("NSMenu") else { return }
            let msgObj = unsafeBitCast(sym, to: MsgObj.self)
            guard
                let alloc = msgObj(menuClass, NSSelectorFromString("alloc")),
                let nsMenu = msgObj(alloc, NSSelectorFromString("init"))
            else { return }

            var newTargets: [ActionTarget] = []
            let addItem = unsafeBitCast(sym, to: MsgItem.self)
            let setVoidObj = unsafeBitCast(sym, to: MsgVoidObj.self)

            for entry in entries {
                if entry.isSeparator {
                    if let sepClass = NSClassFromString("NSMenuItem"),
                       let sep = msgObj(sepClass, NSSelectorFromString("separatorItem")) {
                        setVoidObj(nsMenu, NSSelectorFromString("addItem:"), sep)
                    }
                    continue
                }
                if let handler = entry.handler {
                    let target = ActionTarget(handler)
                    newTargets.append(target)
                    if let mi = addItem(
                        nsMenu, NSSelectorFromString("addItemWithTitle:action:keyEquivalent:"),
                        entry.title as AnyObject, NSSelectorFromString("fire"), "" as AnyObject) {
                        setVoidObj(mi, NSSelectorFromString("setTarget:"), target)
                    }
                } else {
                    // No handler -> no action -> autoenable greys it (label/disabled row).
                    _ = addItem(
                        nsMenu, NSSelectorFromString("addItemWithTitle:action:keyEquivalent:"),
                        entry.title as AnyObject, Selector(("")), "" as AnyObject)
                }
            }

            let setMenu = unsafeBitCast(sym, to: MsgVoidObj.self)
            setMenu(item, NSSelectorFromString("setMenu:"), nsMenu)
            self.menu = nsMenu
            self.targets = newTargets
        }
    }
}
