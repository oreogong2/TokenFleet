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

                    Toggle("", isOn: Binding(
                        get: { appState.autostartEnabled },
                        set: { appState.setAutostart($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
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

struct SettingsUpdateCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: L("自动更新"), symbol: "arrow.down.circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("自动检查 TokenFleet 新版本"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(UpdateService.isConfigured
                            ? L("有更新时先提醒你，下载前会确认。")
                            : L("当前是源码安装版，在线检查更新暂不可用；请按人工升级流程迁移到签名公证版。"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { UpdateService.isConfigured && appState.settings.autoUpdateEnabled },
                        set: { appState.setAutoUpdateEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!UpdateService.isConfigured)
                }

                VStack(spacing: 8) {
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
                }

                HStack(spacing: 10) {
                    StatusLine(
                        symbol: !UpdateService.isConfigured ? "exclamationmark.triangle.fill" : appState.availableUpdate == nil ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                        title: !UpdateService.isConfigured ? L("检查更新暂不可用") : appState.availableUpdate == nil ? LFormat("当前版本 %@", UpdateService.currentVersion) : LFormat("发现 %@", appState.availableUpdate?.version ?? ""),
                        value: updateCheckStatus,
                        tint: !UpdateService.isConfigured ? .orange : appState.availableUpdate == nil ? .tokenGreen : .tokenGreenDark
                    )

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

    var body: some View {
        SettingsCard(title: L("隐私状态"), symbol: "checkmark.shield.fill", height: 292) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color.tokenGreenDark)
                        .frame(width: 38, height: 38)
                        .background(Color.tokenMint.opacity(0.30), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("本地隐私保护已开启"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("代码与对话不会离开这台 Mac"))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tokenMint.opacity(0.18), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                VStack(spacing: 8) {
                    PrivacyCheckRow(title: L("只统计 token 数量"))
                    PrivacyCheckRow(title: L("不读取代码与对话"))
                    PrivacyCheckRow(title: L("不默认上传数据"))
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
