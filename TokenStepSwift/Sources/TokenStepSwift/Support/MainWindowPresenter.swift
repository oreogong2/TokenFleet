import AppKit
import SwiftUI

final class MainWindowNavigation: ObservableObject {
    @Published private(set) var section: AppSection
    @Published private(set) var todayToolExpansionRequest = 0
    var onSectionChange: ((AppSection) -> Void)?

    init(section: AppSection = .today) {
        self.section = section
    }

    func select(_ section: AppSection) {
        self.section = section
        onSectionChange?(section)
    }

    func requestTodayToolExpansion() {
        select(.today)
        todayToolExpansionRequest &+= 1
    }
}

@MainActor
final class MainWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = MainWindowPresenter()

    private var window: NSWindow?
    private weak var appState: AppState?
    private let navigation = MainWindowNavigation()

    func show(appState: AppState, section: AppSection? = nil) {
        self.appState = appState
        if let section {
            navigation.select(section)
        }
        let window = self.window ?? makeWindow(appState: appState)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        closeTransientPanels(except: window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        appState.setForegroundRefreshSurface("main-window", visible: true)
    }

    func showTodayTools(appState: AppState) {
        show(appState: appState, section: .today)
        navigation.requestTodayToolExpansion()
    }

    private func makeWindow(appState: AppState) -> NSWindow {
        let rootView = MainWindowView(navigation: navigation)
            .environmentObject(appState)
            .frame(minWidth: 1040, minHeight: 680)

        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = mainWindowTitle(for: navigation.section)
        window.appearance = NSAppearance(named: .aqua)
        window.identifier = NSUserInterfaceItemIdentifier("tokenfleet.main")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 1040, height: 680)
        window.maxSize = NSSize(width: 1440, height: 980)
        window.setContentSize(NSSize(width: 1180, height: 719))
        window.center()
        window.setFrameAutosaveName("TokenFleetMainWindow.v2")
        navigation.onSectionChange = { [weak window] section in
            window?.title = mainWindowTitle(for: section)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        appState?.setForegroundRefreshSurface("main-window", visible: false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        appState?.setForegroundRefreshSurface("main-window", visible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        appState?.setForegroundRefreshSurface("main-window", visible: true)
    }

    private func closeTransientPanels(except mainWindow: NSWindow) {
        for window in NSApp.windows where window !== mainWindow && window.title.isEmpty {
            window.close()
        }
    }
}

private func mainWindowTitle(for section: AppSection) -> String {
    "TokenFleet beta.8 · \(section.title)"
}
