import SwiftUI

struct SettingsDisplayCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("菜单栏入口"), symbol: "circle.dotted", height: 218) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("显示方式"))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("固定使用 macOS 原生菜单栏，避免遮挡其它状态图标。"))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                StatusLine(
                    symbol: "circle.dotted",
                    title: L("当前入口"),
                    value: L("原生菜单栏 · 圆环进度"),
                    tint: .tokenGreen
                )

                SettingsToggleRow(
                    title: L("菜单栏显示今日 Token"),
                    isOn: Binding(
                        get: { appState.settings.menuBarShowsTokenCount },
                        set: { appState.setMenuBarTokenCountVisible($0) }
                    )
                )

                SettingsToggleRow(
                    title: L("Agent 额度显示"),
                    isOn: Binding(
                        get: { appState.settings.showCodexQuota },
                        set: { appState.setCodexQuotaVisible($0) }
                    )
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(L("当前使用方式（只读）"))
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.78))
                    menuStatusLine("circle.dotted", L("点击圆环图标 → 完整详情浮窗"))
                    menuStatusLine("arrow.up.left.and.arrow.down.right", L("主窗口找回 → 从应用程序或 Spotlight 随时打开"))
                    menuStatusLine("xmark.rectangle", L("关闭主窗口 → 继续菜单栏统计"))
                }
                .padding(.top, 2)
            }
        }
    }

    private func menuStatusLine(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.tokenGreenDark)
                .frame(width: 12)
            Text(title)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 0)
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
        SettingsCard(title: L("实验 Agent 来源"), symbol: "point.3.connected.trianglepath.dotted", height: 710) {
            VStack(alignment: .leading, spacing: 13) {
                SettingsToggleRow(
                    title: L("启用下列实验 Agent 来源"),
                    isOn: Binding(
                        get: { appState.settings.showExperimentalAgentSources },
                        set: { appState.setExperimentalAgentSourcesVisible($0) }
                    )
                )

                Text(L("只读取本地 usage 字段，不读取对话正文。"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        sourceLine(name: "ZCode", sourceKey: "ZCode")
                        sourceLine(name: "Hermes Agent", sourceKey: "Hermes Agent")
                        sourceLine(name: "WorkBuddy", sourceKey: "WorkBuddy")
                        sourceLine(name: "CodeBuddy", sourceKey: "CodeBuddy")
                        sourceLine(name: "Qoder", sourceKey: "Qoder")
                        sourceLine(name: "Kimi", sourceKey: "Kimi")
                        sourceLine(name: "OpenCode", sourceKey: "OpenCode")
                        sourceLine(name: "Grok", sourceKey: "Grok")
                        sourceLine(name: "Qwen Code", sourceKey: "Qwen Code")
                        sourceLine(name: "Cursor", sourceKey: "Cursor")
                        sourceLine(name: "Cline", sourceKey: "Cline")
                        sourceLine(name: "Copilot CLI", sourceKey: "Copilot CLI")
                        sourceLine(name: "Copilot Chat / CLI OTel", sourceKey: "Copilot OTel")
                        sourceLine(name: "Antigravity", sourceKey: "Antigravity")
                        sourceLine(name: "Droid", sourceKey: "Droid")
                        sourceLine(name: "dsh", sourceKey: "dsh")
                        sourceLine(name: "Pi", sourceKey: "Pi")
                        sourceLine(name: "OpenClaw", sourceKey: "OpenClaw")
                    }
                }
                .frame(height: 360)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Cursor 个人账号请从 Dashboard 导出 Usage CSV 后导入。"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            appState.chooseAndImportCursorUsageCSV()
                        } label: {
                            Label(L("导入 Cursor CSV"), systemImage: "square.and.arrow.down")
                                .font(.caption.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())

                        Button {
                            appState.removeCursorImportedUsage()
                        } label: {
                            Text(L("删除导入数据"))
                                .font(.caption.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(appState.cursorImportedUsageRecordCount == nil)
                    }

                    if let status = appState.cursorImportStatus {
                        Text(status)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.tokenInk.opacity(0.7))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func sourceLine(name: String, sourceKey: String) -> some View {
        let status = normalizedStatus(appState.snapshot.sources[sourceKey]?.status)
        let active = status == "ok"
        let refreshing = status == "refreshing" || status == "pending_refresh"
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.tokenInk)
                Text(L("本地只读 usage 数据"))
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText(status))
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(active ? Color.tokenGreenDark : refreshing ? .orange : .secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.tokenTrack.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func normalizedStatus(_ status: String?) -> String {
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

    private func statusText(_ status: String) -> String {
        switch status {
        case "ok": return L("已计入实验统计")
        case "discovered_no_usage": return L("已发现，暂不可统计")
        case "refreshing": return L("刷新中")
        case "pending_refresh": return L("等待刷新")
        case "disabled": return L("默认关闭")
        case "missing_db", "missing", "missing_import": return L("未发现数据源")
        case "missing_valid_rows": return L("暂无可用 usage")
        case "schema_mismatch", "schema_unreadable", "missing_table": return L("结构待适配")
        case "unreadable_db", "unreadable_import": return L("无法读取")
        case "missing_decoder": return L("缺少 zstd 解码器")
        case "partial_missing_decoder": return L("部分压缩日志缺少 zstd 解码器")
        case "deduped_by_session_store": return L("CLI 已由本地库计入")
        default: return L("等待同步")
        }
    }
}
