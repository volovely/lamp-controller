// MenuBarController.swift
// Owns the menu-bar NSStatusItem (via AppKitBridge) and drives it from AppModel.
// The menu CONTENTS are a pure function (menuModel) so they're unit-testable
// without AppKit.

import Foundation
import UIKit

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

@MainActor
final class MenuBarController {
    private let model: AppModel
    private var statusItem: AppKitBridge.StatusItem?

    init(model: AppModel) {
        self.model = model
        statusItem = AppKitBridge.StatusItem(title: "💡")
        if statusItem == nil {
            // Defensive: no menu-bar surface -> at least show the window.
            Self.showActivityWindow()
        }
        model.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    private func rebuild() {
        guard let statusItem else { return }
        let m = MenuBarMenu.menuModel(
            runState: model.runState,
            homeKit: model.homeKitState,
            configError: model.configError)

        var entries: [AppKitBridge.Entry] = [
            AppKitBridge.Entry(title: m.statusLine, handler: nil),  // disabled label
            .separator(),
        ]
        for item in m.items {
            let handler: (@MainActor () -> Void)? = item.enabled
                ? { @MainActor [weak self] in guard let self else { return }; self.perform(item.action) }
                : nil
            entries.append(AppKitBridge.Entry(title: item.title, handler: handler))
        }
        statusItem.setMenu(entries)
    }

    private func perform(_ action: MenuActionKind) {
        switch action {
        case .toggle:
            if model.runState == .running { model.stop() } else { model.start() }
        case .showActivity:
            Self.showActivityWindow()
        case .quit:
            model.stop()
            exit(0)
        }
    }

    /// Open (or focus) the Activity window via the UIKit scene API — Catalyst can
    /// import UIKit, so no AppKit runtime needed for windows.
    static func showActivityWindow() {
        let options = UIScene.ActivationRequestOptions()
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: nil, options: options, errorHandler: nil)
    }
}
