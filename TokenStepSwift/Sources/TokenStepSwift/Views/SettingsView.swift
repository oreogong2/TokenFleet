import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    var captureMode: Bool
    @State private var section: TokenFleetSettingsSection

    init(captureMode: Bool = false) {
        self.captureMode = captureMode
        _section = State(initialValue: .general)
    }

    private init(captureMode: Bool, initialSection: TokenFleetSettingsSection) {
        self.captureMode = captureMode
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        ZStack {
            TokenStepBackdrop()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)

                Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)

                HStack(alignment: .top, spacing: 0) {
                    navigation
                    Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                    ScrollView(.vertical, showsIndicators: false) {
                        sectionContent
                            .padding(.horizontal, 24)
                            .padding(.vertical, 22)
                    }
                }

                Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
                footer
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 980, height: 780)
        .id(appState.appearanceID)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(TokenFleetSettingsSection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        section = item
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .heavy))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.heavy))
                            Text(item.subtitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(section == item ? Color.tokenSurface.opacity(0.74) : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? Color.tokenSurface : Color.tokenInk.opacity(0.74))
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                    .background(section == item ? Color.tokenInk : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                Label(L("本地统计"), systemImage: "lock.shield.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.tokenGreenDark)
                Text(L("代码与对话不会上传"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.tokenMint.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .padding(16)
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tokenSurface.opacity(0.72))
    }

    @ViewBuilder
    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeading(section: section)
            switch section {
            case .general:
                SettingsThemeCard()
                HStack(alignment: .top, spacing: 18) {
                    SettingsGoalCard()
                    SettingsLanguageCard()
                }
                HStack(alignment: .top, spacing: 18) {
                    SettingsDisplayCard()
                    SettingsAutostartCard()
                }
            case .statistics:
                HStack(alignment: .top, spacing: 18) {
                    SettingsRefreshCard()
                    SettingsPrivacyCard()
                }
                SettingsExperimentalAgentSourcesCard()
            case .community:
                SettingsTeamSyncCard()
                SettingsCommunityCapacityNotice()
            case .system:
                SettingsUpdateCard()
                SettingsSystemUpdateBoundary()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            TokenFleetSignalMark(size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("设置"))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(L("让 TokenFleet 按你的节奏记录 Token 消耗"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color.tokenGreen).frame(width: 8, height: 8)
                Text(appState.settings.teamSyncEnabled && appState.isCommunitySyncEnrollmentCompatible
                     ? L("本地统计 + 社群榜日汇总") : L("本地统计"))
                    .font(.callout.weight(.heavy))
                    .foregroundStyle(Color.tokenGreenDark)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.tokenMint.opacity(0.22), in: Capsule())

            if !isScreenshotRendering && !captureMode {
                ScreenshotMenuButton(
                    copyTitle: L("复制设置截图"),
                    saveTitle: L("保存设置 PNG"),
                    help: L("截取设置页"),
                    copyAction: copySettingsScreenshot,
                    saveAction: saveSettingsScreenshot
                )
            }
        }
    }

    private var settingsScreenshot: some View {
        SettingsView(captureMode: true, initialSection: section)
            .environmentObject(appState)
            .environment(\.isScreenshotRendering, true)
    }

    private func copySettingsScreenshot() {
        do { try ScreenshotExporter.copy(settingsScreenshot) }
        catch { appState.lastError = error.localizedDescription }
    }

    private func saveSettingsScreenshot() {
        do {
            try ScreenshotExporter.save(
                settingsScreenshot,
                suggestedFileName: ScreenshotExporter.suggestedFileName(prefix: "settings-\(section.rawValue)")
            )
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("TokenFleet · Local usage tracker"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(LFormat("当前版本 %@", UpdateService.currentVersion))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.82))
            }
            Spacer()
            Button(action: restoreDefaults) {
                Text(L("恢复默认"))
                    .font(.callout.weight(.bold))
                    .frame(width: 92, height: 34)
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            Button {
                SettingsWindowPresenter.shared.close()
                NSApp.keyWindow?.close()
            } label: {
                Text(L("完成"))
                    .font(.callout.weight(.heavy))
                    .frame(width: 82, height: 34)
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
        }
    }

    private func restoreDefaults() {
        appState.setGoal(TokenStepSettings.defaults.dailyGoalTokens)
        appState.setRefreshInterval(TokenStepSettings.defaults.refreshIntervalSeconds)
        appState.setTheme(TokenStepSettings.defaults.theme)
        appState.setLanguage(TokenStepSettings.defaults.language)
        appState.setAutoUpdateEnabled(TokenStepSettings.defaults.autoUpdateEnabled)
        appState.setAskBeforeDownloadingUpdates(TokenStepSettings.defaults.askBeforeDownloadingUpdates)
        appState.setRequireVerifiedUpdates(TokenStepSettings.defaults.requireVerifiedUpdates)
        appState.setTokenIslandPlacement(TokenStepSettings.defaults.tokenIslandPlacement)
        appState.setCodexQuotaVisible(TokenStepSettings.defaults.showCodexQuota)
        appState.setExperimentalAgentSourcesVisible(TokenStepSettings.defaults.showExperimentalAgentSources)
        appState.setAutostart(true)
    }
}

private enum TokenFleetSettingsSection: String, CaseIterable, Identifiable {
    case general
    case statistics
    case community
    case system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("通用与显示")
        case .statistics: return L("统计与采集")
        case .community: return L("社群同步")
        case .system: return L("系统与更新")
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("主题、目标、入口")
        case .statistics: return L("刷新、来源、隐私")
        case .community: return L("设备、成员、榜单")
        case .system: return L("版本与可信升级")
        }
    }
    var detail: String {
        switch self {
        case .general: return L("调整外观、每日目标、语言和启动方式。")
        case .statistics: return L("控制采集频率和实验来源；Token 不等于工时或绩效。")
        case .community: return L("管理当前设备与同一成员的聚合同步，不重复创建成员。")
        case .system: return L("源码安装版不伪装在线更新；签名版必须通过可信更新链。")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .statistics: return "chart.bar.xaxis"
        case .community: return "person.3.fill"
        case .system: return "gearshape.2.fill"
        }
    }
}

private struct SettingsSectionHeading: View {
    var section: TokenFleetSettingsSection
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tokenInk)
            Text(section.detail)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsCommunityCapacityNotice: View {
    var body: some View {
        SettingsCard(title: L("成员与设备边界"), symbol: "person.2.badge.gearshape.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("单批最多 50，可创建多个批次进入同一社群"), systemImage: "person.3.sequence.fill")
                Label(L("新设备必须由管理员给既有成员补发设备码"), systemImage: "key.horizontal.fill")
                Label(L("多台设备各自独立，用量按同一成员聚合"), systemImage: "laptopcomputer.and.iphone")
                Label(L("停用单台设备不会删除成员或旧历史"), systemImage: "externaldrive.badge.xmark")
            }
            .font(.callout.weight(.heavy))
            .foregroundStyle(Color.tokenInk.opacity(0.76))
        }
    }
}

private struct SettingsSystemUpdateBoundary: View {
    var body: some View {
        SettingsCard(title: L("正式更新门槛"), symbol: "checkmark.seal.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("可信 HTTPS 更新源"), systemImage: "network.badge.shield.half.filled")
                Label(L("固定 Developer Team ID、签名与公证"), systemImage: "signature")
                Label(L("下载前显式确认，失败可回滚到旧 App"), systemImage: "arrow.uturn.backward.circle.fill")
            }
            .font(.callout.weight(.heavy))
            .foregroundStyle(Color.tokenInk.opacity(0.76))
        }
    }
}
