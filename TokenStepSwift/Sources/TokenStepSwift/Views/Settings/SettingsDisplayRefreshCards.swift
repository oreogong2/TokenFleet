import SwiftUI

struct SettingsDisplayCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("显示入口"), symbol: "macwindow.badge.plus", height: 338) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("显示位置"))
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("刘海屏显示在刘海旁，其他屏幕使用菜单栏。"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    ForEach(TokenIslandDisplayPlacement.allCases) { placement in
                        DisplayPlacementButton(
                            title: placement.shortTitle,
                            selected: appState.settings.tokenIslandPlacement == placement
                        ) {
                            appState.setTokenIslandPlacement(placement)
                        }
                    }
                }

                StatusLine(
                    symbol: appState.shouldShowTokenIsland ? "circle.dotted.circle.fill" : "menubar.rectangle",
                    title: appState.tokenIslandStatus,
                    value: appState.tokenIslandStatusDetail,
                    tint: appState.shouldShowTokenIsland ? .tokenGreen : .gray
                )

                SettingsToggleRow(
                    title: L("菜单栏显示今日 Token"),
                    isOn: Binding(
                        get: { appState.settings.menuBarShowsTokenCount },
                        set: { appState.setMenuBarTokenCountVisible($0) }
                    )
                )

                Text(L("默认关闭，更适合单屏或菜单栏拥挤的 Mac。"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SettingsToggleRow(
                    title: L("Agent 额度显示"),
                    isOn: Binding(
                        get: { appState.settings.showCodexQuota },
                        set: { appState.setCodexQuotaVisible($0) }
                    )
                )
            }
        }
    }
}

struct SettingsRefreshCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("自动刷新"), symbol: "arrow.triangle.2.circlepath.circle.fill") {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("面板可见时按此频率检查；后台会根据供电状态降低频率。"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(refreshOptions) { option in
                        RefreshOptionButton(
                            title: option.title,
                            selected: appState.settings.refreshIntervalSeconds == option.seconds
                        ) {
                            appState.setRefreshInterval(option.seconds)
                        }
                    }
                }

                StatusLine(
                    symbol: appState.settings.refreshIntervalSeconds == 0 ? "hand.raised.fill" : "timer",
                    title: L("当前节奏"),
                    value: appState.settings.refreshIntervalSeconds == 0 ? L("手动更新") : LFormat("每 %@", TokenStepFormat.intervalLabel(appState.settings.refreshIntervalSeconds)),
                    tint: .tokenGreen
                )

                Spacer(minLength: 0)
            }
        }
    }

    private var refreshOptions: [RefreshOption] {
        [
            RefreshOption(seconds: 60, title: L("1 分钟")),
            RefreshOption(seconds: 300, title: LFormat("%d 分钟", 5)),
            RefreshOption(seconds: 900, title: LFormat("%d 分钟", 15)),
            RefreshOption(seconds: 0, title: L("手动"))
        ]
    }
}

struct SettingsExperimentalAgentSourcesCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("实验 Agent 来源"), symbol: "point.3.connected.trianglepath.dotted", height: 282) {
            VStack(alignment: .leading, spacing: 13) {
                SettingsToggleRow(
                    title: L("启用 ZCode / Hermes"),
                    isOn: Binding(
                        get: { appState.settings.showExperimentalAgentSources },
                        set: { appState.setExperimentalAgentSourcesVisible($0) }
                    )
                )

                Text(L("只读取本地 usage 字段，不读取对话正文。"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    experimentalSourceLine(name: "ZCode", sourceKey: "ZCode")
                    experimentalSourceLine(name: "Hermes Agent", sourceKey: "Hermes Agent")
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func experimentalSourceLine(name: String, sourceKey: String) -> some View {
        let rawStatus = appState.snapshot.sources[sourceKey]?.status
        let status = normalizedExperimentalStatus(rawStatus)
        let active = status == "ok"
        let discoveredOnly = status == "discovered_no_usage"
        return StatusLine(
            symbol: active ? "checkmark.circle.fill" : discoveredOnly ? "magnifyingglass.circle.fill" : "circle.dashed",
            title: name,
            value: statusText(status),
            tint: active ? .tokenGreen : discoveredOnly ? .orange : .gray
        )
    }

    private func normalizedExperimentalStatus(_ status: String?) -> String {
        guard appState.settings.showExperimentalAgentSources else {
            return "disabled"
        }
        if appState.isRefreshing {
            return "refreshing"
        }
        if status == nil || status == "disabled" {
            return "pending_refresh"
        }
        return status ?? "missing"
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "ok": return L("已计入实验统计")
        case "discovered_no_usage": return L("已发现，暂不可统计")
        case "refreshing": return L("刷新中")
        case "pending_refresh": return L("等待刷新")
        case "disabled": return L("默认关闭")
        case "missing_db", "missing": return L("未发现数据源")
        case "missing_valid_rows": return L("暂无可用 usage")
        case "schema_mismatch", "schema_unreadable", "missing_table": return L("结构待适配")
        case "unreadable_db": return L("无法读取")
        default: return L("等待同步")
        }
    }
}
