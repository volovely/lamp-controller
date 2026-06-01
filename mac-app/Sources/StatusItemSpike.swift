// StatusItemSpike.swift
// Feasibility spike: create a working NSStatusItem with a clickable NSMenu
// entirely through the ObjC runtime (NSClassFromString + objc_msgSend).
// No AppKit import, no separate bundle — Mac Catalyst only.
//
// NOT production code. Kept in-tree as evidence for the feasibility verdict.

import Foundation
import Darwin
import os.log

private let spikeLog = OSLog(subsystem: "com.volovely.lamp-controller", category: "StatusItemSpike")

/// Write to both unified log (fault level = always stored) and a plain log file.
private func slog(_ msg: String) {
    os_log("%{public}@", log: spikeLog, type: .fault, msg)
    let line = "\(Date()) [StatusItemSpike] \(msg)\n"
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/lamp_spike.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - objc_msgSend raw symbol

private nonisolated(unsafe) let objcMsgSendSym: UnsafeMutableRawPointer? =
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

// MARK: - @convention(c) typealiases

/// (receiver, sel) -> AnyObject?   — used for zero-arg accessors that return objects
private typealias MsgObj = @convention(c) (AnyObject, Selector) -> AnyObject?

/// (receiver, sel, CGFloat) -> AnyObject?  — statusItemWithLength:
private typealias MsgObjCGFloat = @convention(c) (AnyObject, Selector, CGFloat) -> AnyObject?

/// (receiver, sel, AnyObject?) -> Void  — setTitle:, setMenu:, setTarget:, addItem:
private typealias MsgVoidObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

/// (receiver, sel, AnyObject?, Selector, AnyObject?) -> AnyObject?
/// — addItemWithTitle:action:keyEquivalent:
private typealias MsgObjObjSelObj =
    @convention(c) (AnyObject, Selector, AnyObject?, Selector, AnyObject?) -> AnyObject?

// MARK: - Tiny ObjC-visible action target

/// Lives as long as StatusItemSpike.shared lives.
/// @objc exposes both selectors to the ObjC runtime so NSMenuItem can call back.
@objc final class StatusItemSpikeTarget: NSObject {
    // Reference back so toggle can flip the button title.
    weak var spike: StatusItemSpike?

    @objc func onToggle() {
        slog("TOGGLE TAPPED")
        spike?.flipTitle()
    }

    @objc func onQuit() {
        slog("QUIT TAPPED — calling exit(0)")
        exit(0)
    }
}

// MARK: - Main spike class

public final class StatusItemSpike {
    public nonisolated(unsafe) static let shared = StatusItemSpike()
    private init() {}

    // Strong references — these must outlive every callback.
    private var statusItem: AnyObject?
    private var menu: AnyObject?
    private let target = StatusItemSpikeTarget()

    private var isOn = true

    /// Call once at app launch. Creates the status bar item + menu via the ObjC runtime.
    public func install() {
        slog("install() called")
        target.spike = self

        guard let sym = objcMsgSendSym else {
            slog("ERROR: could not load objc_msgSend")
            return
        }

        // ------------------------------------------------------------------
        // 1. [NSStatusBar systemStatusBar]
        // ------------------------------------------------------------------
        guard let statusBarClass = NSClassFromString("NSStatusBar") else {
            slog("ERROR: NSStatusBar not found")
            return
        }
        let getSystemBar = unsafeBitCast(sym, to: MsgObj.self)
        guard let systemBar = getSystemBar(statusBarClass, NSSelectorFromString("systemStatusBar")) else {
            slog("ERROR: systemStatusBar returned nil")
            return
        }
        slog("Got systemStatusBar OK")

        // ------------------------------------------------------------------
        // 2. [systemBar statusItemWithLength:-1]   (NSVariableStatusItemLength)
        // ------------------------------------------------------------------
        let getItem = unsafeBitCast(sym, to: MsgObjCGFloat.self)
        guard let item = getItem(systemBar, NSSelectorFromString("statusItemWithLength:"), -1) else {
            slog("ERROR: statusItemWithLength: returned nil")
            return
        }
        statusItem = item
        slog("Got statusItem OK")

        // ------------------------------------------------------------------
        // 3. statusItem.button — get the NSStatusBarButton, set its title
        // ------------------------------------------------------------------
        let getButton = unsafeBitCast(sym, to: MsgObj.self)
        if let button = getButton(item, NSSelectorFromString("button")) {
            let setTitle = unsafeBitCast(sym, to: MsgVoidObj.self)
            setTitle(button, NSSelectorFromString("setTitle:"), "\u{1F4A1}" as AnyObject)
            slog("Set button title to bulb emoji OK")
        } else {
            slog("WARNING: button is nil")
        }

        // ------------------------------------------------------------------
        // 4. Build NSMenu with two items
        // ------------------------------------------------------------------
        guard let menuClass = NSClassFromString("NSMenu") else {
            slog("ERROR: NSMenu not found")
            return
        }
        // [[NSMenu alloc] init]
        let allocSel = NSSelectorFromString("alloc")
        let initSel  = NSSelectorFromString("init")
        let alloc = unsafeBitCast(sym, to: MsgObj.self)
        guard let menuAlloc = alloc(menuClass, allocSel) else {
            slog("ERROR: NSMenu alloc returned nil")
            return
        }
        let initMsg = unsafeBitCast(sym, to: MsgObj.self)
        guard let nsMenu = initMsg(menuAlloc, initSel) else {
            slog("ERROR: NSMenu init returned nil")
            return
        }
        menu = nsMenu
        slog("Created NSMenu OK")

        // addItemWithTitle:action:keyEquivalent: — returns NSMenuItem
        let addItemSel = NSSelectorFromString("addItemWithTitle:action:keyEquivalent:")
        let addItem = unsafeBitCast(sym, to: MsgObjObjSelObj.self)

        // Item 1: Toggle
        let toggleItem = addItem(
            nsMenu,
            addItemSel,
            "Toggle (spike)" as AnyObject,
            NSSelectorFromString("onToggle"),
            "" as AnyObject
        )
        if let ti = toggleItem {
            let setTarget = unsafeBitCast(sym, to: MsgVoidObj.self)
            setTarget(ti, NSSelectorFromString("setTarget:"), target)
            slog("Added Toggle item OK")
        }

        // Item 2: Quit
        let quitItem = addItem(
            nsMenu,
            addItemSel,
            "Quit" as AnyObject,
            NSSelectorFromString("onQuit"),
            "" as AnyObject
        )
        if let qi = quitItem {
            let setTarget = unsafeBitCast(sym, to: MsgVoidObj.self)
            setTarget(qi, NSSelectorFromString("setTarget:"), target)
            slog("Added Quit item OK")
        }

        // ------------------------------------------------------------------
        // 5. statusItem.menu = nsMenu
        // ------------------------------------------------------------------
        let setMenu = unsafeBitCast(sym, to: MsgVoidObj.self)
        setMenu(item, NSSelectorFromString("setMenu:"), nsMenu)

        slog("install() COMPLETE — status bar item should now be visible")

        // AUTO-TOGGLE: fire the toggle callback programmatically after 2 s to prove
        // the callback path works end-to-end without needing a real click.
        // Use perform(_:with:afterDelay:) to stay on main run loop without Swift 6 actor issues.
        target.perform(#selector(StatusItemSpikeTarget.onToggle), with: nil, afterDelay: 2.0)
        target.perform(#selector(StatusItemSpikeTarget.onToggle), with: nil, afterDelay: 4.0)
    }

    // Called by onToggle to flip the button title.
    func flipTitle() {
        guard let sym = objcMsgSendSym, let item = statusItem else { return }
        let getButton = unsafeBitCast(sym, to: MsgObj.self)
        guard let button = getButton(item, NSSelectorFromString("button")) else { return }
        isOn.toggle()
        let newTitle = isOn ? "\u{1F4A1}" : "\u{1F50C}"
        let setTitle = unsafeBitCast(sym, to: MsgVoidObj.self)
        setTitle(button, NSSelectorFromString("setTitle:"), newTitle as AnyObject)
        slog("title flipped to \(newTitle)")
    }
}
