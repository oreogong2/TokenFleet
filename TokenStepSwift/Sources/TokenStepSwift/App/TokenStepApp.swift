import AppKit
import Darwin
import SwiftUI

final class TokenStepAppDelegate: NSObject, NSApplicationDelegate {
    private let reopenHandler: @MainActor (String) -> Void

    override init() {
        reopenHandler = { reason in
            TokenStepReopenObserver.shared.request(reason: reason)
        }
        super.init()
    }

    init(reopenHandler: @escaping @MainActor (String) -> Void) {
        self.reopenHandler = reopenHandler
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = signal(SIGPIPE, SIG_IGN)
        guard SingleInstanceGuard.claimOrTerminateDuplicate() else { return }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LifecycleLogger.log(
            "Application launched pid=\(ProcessInfo.processInfo.processIdentifier), version=\(UpdateService.currentVersion), bundle=\(Bundle.main.bundleURL.path)."
        )
        if let url = Bundle.main.url(forResource: "TokenFleetIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // A native status item may be hidden by macOS when the built-in display's
        // menu bar is crowded around the camera housing. Reopening TokenFleet from
        // Applications or Spotlight must therefore remain a reliable way back to
        // the main window even when the menu-bar ring is not currently visible.
        reopenHandler("application_reopen")
        return false
    }
}

@main
struct TokenStepApp: App {
    @NSApplicationDelegateAdaptor(TokenStepAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverPanelView()
                .environmentObject(appState)
        } label: {
            Group {
                StatusBarLabelView(
                    tokens: appState.today.totalTokens,
                    lap: appState.todayLap,
                    refreshing: appState.isRefreshing,
                    theme: appState.settings.theme,
                    language: appState.settings.language,
                    showsTokenCount: appState.settings.menuBarShowsTokenCount
                )
            }
            .id(appState.appearanceID)
            .onAppear {
                TokenStepReopenObserver.shared.bind(appState: appState)
                TokenIslandWindowPresenter.shared.bind(appState: appState)
                #if TOKENSTEP_TESTING
                if ProcessInfo.processInfo.environment[
                    "TOKENFLEET_TEST_OPEN_MAIN_WINDOW"
                ] == "1" {
                    Task { @MainActor in
                        MainWindowPresenter.shared.show(appState: appState)
                    }
                }
                #endif
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .commands {
            CommandMenu("TokenFleet") {
                Button(L("刷新")) {
                    appState.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(L("打开 TokenFleet")) {
                    MainWindowPresenter.shared.show(appState: appState)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(L("设置")) {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
