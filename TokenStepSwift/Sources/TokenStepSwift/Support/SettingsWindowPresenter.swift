import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?

    func show(appState: AppState) {
        let window = self.window ?? makeWindow(appState: appState)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        closeTransientPanels(except: window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    private func makeWindow(appState: AppState) -> NSWindow {
        let rootView = SettingsView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = "TokenFleet \(UpdateService.currentVersion) · \(L("设置"))"
        window.appearance = NSAppearance(named: .aqua)
        window.identifier = NSUserInterfaceItemIdentifier("tokenfleet.settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 719)
        window.setContentSize(NSSize(width: 980, height: 719))
        window.center()
        window.setFrameAutosaveName("TokenFleetSettingsWindow")
        return window
    }

    private func closeTransientPanels(except settingsWindow: NSWindow) {
        for window in NSApp.windows where window !== settingsWindow && window.title.isEmpty {
            window.close()
        }
    }
}
