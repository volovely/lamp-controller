// AppKitBridge.swift
// The ONLY file in this app that reaches AppKit via the ObjC runtime.
// Mac Catalyst cannot `import AppKit`, so NSApplication / NSStatusBar / NSMenu
// are reached through NSClassFromString + dlsym(objc_msgSend). Everything
// objc_msgSend-shaped lives here and nowhere else.

import Foundation
import Darwin

enum AppKitBridge {
    /// Flip the process to NSApplicationActivationPolicyAccessory (== 1):
    /// no Dock icon, no window required, and — critically — foreground-active
    /// enough for HomeKit writes to succeed.
    static func setAccessoryActivationPolicy() {
        guard
            let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
            let sharedApp = appClass.value(forKey: "sharedApplication") as? NSObject,
            let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
        else { return }
        typealias SetPolicyFn = @convention(c) (AnyObject, Selector, Int) -> Bool
        let fn = unsafeBitCast(sym, to: SetPolicyFn.self)
        _ = fn(sharedApp, NSSelectorFromString("setActivationPolicy:"), 1)
    }
}
