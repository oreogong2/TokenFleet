import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    var captureMode: Bool
    @State private var section: TokenFleetSettingsSection

    init(
        captureMode: Bool = false,
        initialSection: TokenFleetSettingsSection = .general
    ) {
        self.captureMode = captureMode
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            navigation
            Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
            if captureMode {
                settingsBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    settingsBody
                }
            }
        }
        .background(TokenStepBackdrop())
        .frame(width: 980, height: 719)
        .id(appState.appearanceID)
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sectionContent
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 21)
        .padding(.bottom, 24)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TokenFleetSignalMark(size: 28)
                Text(L("TokenFleet 设置"))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            ForEach(TokenFleetSettingsSection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        section = item
                    }
                } label: {
                    HStack {
                        Text(item.title).font(.system(size: 10, weight: .heavy))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? Color.tokenSurface : Color.tokenInk.opacity(0.74))
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(section == item ? Color.tokenInk : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }

            Spacer()

            Text(L("设置页只保留这一层导航；返回今日、历史和榜单使用窗口左上角或菜单栏入口。"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 19)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.tokenTrack.opacity(0.42))
    }

    @ViewBuilder
    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch section {
            case .general:
                HStack(alignment: .top, spacing: 10) {
                    SettingsLanguageCard()
                    SettingsGoalCard()
                }
                HStack(alignment: .top, spacing: 10) {
                    SettingsDisplayCard()
                    SettingsAutostartCard()
                }
                SettingsThemeCard()
            case .statistics:
                HStack(alignment: .top, spacing: 10) {
                    SettingsRefreshCard()
                    SettingsPricingSummaryCard()
                }
                HStack(alignment: .top, spacing: 10) {
                    SettingsPrivacyCard(compact: true)
                    SettingsExperimentalAgentSourcesCard()
                }
                SettingsCollectorStatusCard()
            case .community:
                SettingsTeamSyncCard()
            case .system:
                HStack(alignment: .top, spacing: 10) {
                    SettingsVersionArchitectureCard()
                    SettingsUpdatePreferencesCard()
                }
                HStack(alignment: .top, spacing: 10) {
                    SettingsUpdateStatusCard()
                    SettingsPrivacyCard()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("设置"))
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(L("让 TokenFleet 按你的节奏记录 Token 消耗"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color.tokenGreen).frame(width: 8, height: 8)
                Text(appState.settings.teamSyncEnabled && appState.isCommunitySyncEnrollmentCompatible
                     ? L("本地统计 + 社群榜日汇总") : L("本地统计"))
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.tokenGreenDark)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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
        SettingsWindowScreenshotView(section: section)
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
            Text(LFormat("TokenFleet · Local usage tracker · 当前版本 %@", UpdateService.currentVersion))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: restoreDefaults) {
                Text(L("恢复默认"))
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 82, height: 30)
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.tokenTrack.opacity(0.34), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.black.opacity(0.07)))
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

private struct SettingsPricingSummaryCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("费用估算"), symbol: "dollarsign.circle.fill", height: 150) {
            VStack(spacing: 0) {
                SettingsVisualRow(label: L("价格口径"), detail: L("公开 API 标准价，不等于实际账单"), value: "USD")
                SettingsVisualRow(
                    label: L("价格目录"),
                    detail: appState.today.pricingVersion ?? L("等待价格目录"),
                    value: appState.today.pricingVersion == nil ? "—" : L("已加载"),
                    tint: appState.today.pricingVersion == nil ? .secondary : .tokenGreenDark
                )
                SettingsVisualRow(label: L("今日可估价 Token"), detail: L("未定价部分不按 0 元处理"), value: TokenStepFormat.pricingCoverage(appState.today.pricingCoverage))
            }
        }
    }
}

private struct SettingsCollectorStatusCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("采集器状态"), symbol: "waveform.path.ecg.rectangle.fill", height: 138) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                SettingsCollectorItem(name: "Codex", detail: L("本地可靠字段"), status: L("正式"), tint: .tokenGreenDark)
                SettingsCollectorItem(name: "Claude Code", detail: L("本地可靠字段"), status: L("正式"), tint: .tokenGreenDark)
                SettingsCollectorItem(name: "CC Switch", detail: L("只接收 proxy 真用量行"), status: L("实验性"), tint: .orange)
                SettingsCollectorItem(
                    name: L("上次刷新"),
                    detail: TokenStepFormat.generatedTime(appState.snapshot.generatedAt),
                    status: appState.isRefreshing
                        ? L("刷新中")
                        : (appState.snapshot.generatedAt == nil ? L("等待刷新") : L("已完成")),
                    tint: .secondary
                )
            }
        }
    }
}

private struct SettingsVersionArchitectureCard: View {
    var body: some View {
        SettingsCard(title: L("版本与架构"), symbol: "shippingbox.fill", height: 150) {
            VStack(spacing: 0) {
                SettingsVisualRow(label: L("当前版本"), detail: L("TokenFleet beta.8"), value: UpdateService.currentVersion)
                SettingsVisualRow(label: L("Mac 架构"), detail: L("Apple Silicon 与 Intel"), value: L("Universal"))
                SettingsVisualRow(label: L("Windows"), detail: L("现有成员路径保持回归"), value: L("受支持"), tint: .tokenGreenDark)
            }
        }
    }
}

private struct SettingsVisualRow: View {
    var label: String
    var detail: String
    var value: String
    var tint: Color = .tokenInk

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.tokenInk)
                Text(detail).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }
}

private struct SettingsCollectorItem: View {
    var name: String
    var detail: String
    var status: String
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.tokenInk)
                Text(detail).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(status).font(.system(size: 7, weight: .heavy)).foregroundStyle(tint)
        }
        .padding(9)
        .background(Color.tokenCanvas.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.06)))
    }
}

enum TokenFleetSettingsSection: String, CaseIterable, Identifiable {
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
        case .system: return L("系统、更新与隐私")
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("主题、目标、入口")
        case .statistics: return L("刷新、来源、隐私")
        case .community: return L("设备、成员、榜单")
        case .system: return L("版本、可信升级与本地统计边界")
        }
    }
    var detail: String {
        switch self {
        case .general: return L("调整外观、每日目标、语言和启动方式。")
        case .statistics: return L("控制采集频率和实验来源；Token 不等于工时或绩效。")
        case .community: return L("管理当前设备与同一成员的聚合同步，不重复创建成员。")
        case .system: return L("源码安装版不伪装在线更新；统计只读本地用量数字，签名版必须通过可信更新链。")
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
