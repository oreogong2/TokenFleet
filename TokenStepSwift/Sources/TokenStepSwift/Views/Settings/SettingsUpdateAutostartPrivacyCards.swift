import SwiftUI

struct SettingsAutostartCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("开机启动"), symbol: "power.circle.fill") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("登录后自动启动 TokenFleet"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("在后台安静记录，避免漏掉每天的 Token 消耗。"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    ScreenshotSafeToggle(isOn: Binding(
                        get: { appState.autostartEnabled },
                        set: { appState.setAutostart($0) }
                    ))
                }

                StatusLine(
                    symbol: appState.autostartEnabled ? "checkmark.circle.fill" : "pause.circle.fill",
                    title: appState.autostartEnabled ? L("已开启") : L("已关闭"),
                    value: appState.autostartEnabled ? L("下次登录会自动运行") : L("需要手动启动 App"),
                    tint: appState.autostartEnabled ? .tokenGreen : .gray
                )
            }
        }
    }
}

struct SettingsUpdatePreferencesCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("更新偏好"), symbol: "arrow.triangle.2.circlepath", height: 178) {
            VStack(spacing: 9) {
                SettingsToggleRow(
                    title: L("自动检查新版本"),
                    isOn: Binding(
                        get: { UpdateService.isConfigured && appState.settings.autoUpdateEnabled },
                        set: { appState.setAutoUpdateEnabled($0) }
                    )
                )
                .disabled(!UpdateService.isConfigured)
                SettingsToggleRow(
                    title: L("下载前询问"),
                    isOn: Binding(
                        get: { appState.settings.askBeforeDownloadingUpdates },
                        set: { appState.setAskBeforeDownloadingUpdates($0) }
                    )
                )
                SettingsToggleRow(
                    title: L("仅安装已签名公证版本"),
                    isOn: .constant(true)
                )
                .disabled(true)
                Text(UpdateService.isConfigured
                     ? L("仅从可信 HTTPS 更新源读取签名公证版本。")
                     : L("源码安装版在安全迁移完成前保持关闭。"))
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SettingsUpdateStatusCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("更新状态"), symbol: "checkmark.shield.fill", height: 178) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UpdateService.isConfigured ? L("可信更新链已配置") : L("当前源码版不能在线检查"))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(UpdateService.isConfigured ? Color.tokenGreenDark : Color.orange)
                    Text(UpdateService.isConfigured
                         ? L("下载前仍会显式确认，失败可回滚。")
                         : L("尚未配置签名、公证和可信更新源；不会连接未知地址，也不会误报可以升级。"))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((UpdateService.isConfigured ? Color.tokenMint : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                StatusLine(
                    symbol: !UpdateService.isConfigured ? "exclamationmark.triangle.fill" : appState.availableUpdate == nil ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                    title: !UpdateService.isConfigured ? L("检查更新暂不可用") : appState.availableUpdate == nil ? LFormat("当前版本 %@", UpdateService.currentVersion) : LFormat("发现 %@", appState.availableUpdate?.version ?? ""),
                    value: updateCheckStatus,
                    tint: !UpdateService.isConfigured ? .orange : appState.availableUpdate == nil ? .tokenGreen : .tokenGreenDark
                )

                HStack {
                    Text(!UpdateService.isConfigured ? L("检查更新：暂不可用") : updateCheckStatus)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    updateActionButton
                }
            }
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        if appState.availableUpdate != nil {
            Button {
                appState.showUpdateDetails()
            } label: {
                Text(appState.isDownloadingUpdate ? L("安装中") : L("立即更新"))
                    .font(.caption.weight(.heavy))
                    .frame(width: 86, height: 34)
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .disabled(appState.isDownloadingUpdate)
        } else {
            Button {
                appState.checkForUpdates(silent: false)
            } label: {
                Text(!UpdateService.isConfigured ? L("暂不可用") : appState.isCheckingForUpdates ? L("检查中") : L("检查更新"))
                    .font(.caption.weight(.heavy))
                    .frame(width: 76, height: 34)
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .disabled(appState.isCheckingForUpdates || !UpdateService.isConfigured)
        }
    }

    private var updateCheckStatus: String {
        if !UpdateService.isConfigured {
            return L("源码安装版不提供在线检查")
        }
        if appState.isCheckingForUpdates {
            return L("正在检查")
        }
        if appState.availableUpdate != nil {
            return L("可更新")
        }
        guard let date = appState.lastUpdateCheckAt else {
            return L("尚未检查")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: date))"
    }
}

struct SettingsPrivacyCard: View {
    @EnvironmentObject private var appState: AppState
    var compact: Bool = false

    var body: some View {
        SettingsCard(title: L("统计隐私"), symbol: "checkmark.shield.fill", height: 196) {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color.tokenGreenDark)
                        .frame(width: compact ? 32 : 38, height: compact ? 32 : 38)
                        .background(Color.tokenMint.opacity(0.30), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("本机处理用量记录"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("仅汇总 Token；内容字段不上传、不进入统计"))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                    }
                }
                .padding(compact ? 8 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tokenMint.opacity(0.18), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                if compact {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                        SettingsPrivacyCompactRow(title: L("保留聚合与去重元数据"))
                        SettingsPrivacyCompactRow(title: L("原始日志仅在本机只读处理"))
                        SettingsPrivacyCompactRow(title: L("内容字段不进入统计或上传"))
                        SettingsPrivacyCompactRow(title: L("路径仅作本机增量定位"))
                    }
                } else {
                    VStack(spacing: 8) {
                        PrivacyCheckRow(title: L("本机结果保留聚合 Token 与必要去重元数据"))
                        PrivacyCheckRow(title: L("原始日志在本机只读处理，不修改"))
                        PrivacyCheckRow(title: L("prompt、回复和代码不进入统计或上传"))
                        PrivacyCheckRow(title: L("本地路径仅用于增量定位，不默认上传"))
                    }

                    HStack(spacing: 8) {
                        PrivacyMetaChip(title: L("本机"))
                        PrivacyMetaChip(title: TokenStepFormat.generatedTime(appState.snapshot.generatedAt))
                        PrivacyMetaChip(title: LFormat("%d 个已采集客户端", appState.snapshot.collectedSourceCount))
                    }
                }
            }
        }
    }
}

private struct SettingsPrivacyCompactRow: View {
    var title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.tokenGreen)
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.tokenInk.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
        }
    }
}
