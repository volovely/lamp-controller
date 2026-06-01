// MenuBarController.swift
// Owns the menu-bar NSStatusItem (via AppKitBridge) and drives it from AppModel.
// The menu CONTENTS are a pure function (menuModel) so they're unit-testable
// without AppKit.

import Foundation

enum MenuActionKind: Equatable { case toggle, showActivity, quit }

struct MenuItem: Equatable {
    let title: String
    let enabled: Bool
    let action: MenuActionKind
}

struct MenuModel: Equatable {
    let statusLine: String
    let items: [MenuItem]
}

enum MenuBarMenu {
    /// Pure: maps app state to the menu contents.
    static func menuModel(
        runState: AppModel.RunState,
        homeKit: HomeKitController.State,
        configError: String?
    ) -> MenuModel {
        let statusLine: String
        if configError != nil {
            statusLine = "⚠ Config error"
        } else if homeKit == .denied {
            statusLine = "⚠ HomeKit denied"
        } else if runState == .running {
            if case .ready(_, accessoryFound: false) = homeKit {
                statusLine = "● Running · accessory not found"
            } else {
                statusLine = "● Running"
            }
        } else {
            statusLine = "○ Stopped"
        }

        // Toggle: Stop is always allowed while running; Start requires config OK
        // and HomeKit ready.
        let isReady: Bool = { if case .ready = homeKit { return true }; return false }()
        let toggle: MenuItem
        if runState == .running {
            toggle = MenuItem(title: "Stop", enabled: true, action: .toggle)
        } else {
            let canStart = configError == nil && isReady
            toggle = MenuItem(title: "Start", enabled: canStart, action: .toggle)
        }

        return MenuModel(statusLine: statusLine, items: [
            toggle,
            MenuItem(title: "Show Activity…", enabled: true, action: .showActivity),
            MenuItem(title: "Quit", enabled: true, action: .quit),
        ])
    }
}
