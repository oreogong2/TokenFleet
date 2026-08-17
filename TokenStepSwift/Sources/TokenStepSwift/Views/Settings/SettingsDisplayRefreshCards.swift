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
    var body: some View {
        SettingsCard(title: L("实验来源"), symbol: "point.3.connected.trianglepath.dotted", height: 180) {
            VStack(spacing: 8) {
                sourceLine(name: L("Kimi / DeepSeek"), detail: L("仅真实 CC Switch 代理行"), status: L("实验性"), tint: .orange)
                sourceLine(name: L("Cursor / Gemini CLI"), detail: L("暂无稳定隐私安全字段"), status: L("暂不支持"), tint: .secondary)
                sourceLine(name: "WorkBuddy", detail: L("不扫描目录或文件"), status: L("暂不支持"), tint: .secondary)
            }
        }
    }

    private func sourceLine(name: String, detail: String, status: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.tokenInk)
                Text(detail).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.system(size: 7, weight: .heavy)).foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.tokenTrack.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
