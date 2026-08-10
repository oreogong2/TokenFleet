import AppKit
import Foundation
import SwiftUI

struct SettingsTeamSyncCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @State private var enrollmentToken = ""
    @State private var showsClearConfirmation = false

    var body: some View {
        SettingsCard(title: L("社群榜同步（可选）"), symbol: "person.3.fill", height: 510) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    connectionControls
                    Divider()
                    privacySummary
                }

                if !TeamSyncCredentialStorageAvailability.isAvailable {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                            .foregroundStyle(.orange)
                        Text(L("当前构建未启用安全凭据存储，社群榜同步保持关闭。"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenInk.opacity(0.72))
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                if appState.communityServerOrigin == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.orange)
                        Text(L("当前构建未配置有效的社群榜服务器，社群榜同步不可用。"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenInk.opacity(0.72))
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                if let error = appState.teamSyncActionError ?? appState.teamSyncState?.lastError,
                   !error.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenInk.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
        .alert(L("清除社群榜连接？"), isPresented: $showsClearConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("清除连接"), role: .destructive) {
                enrollmentToken = ""
                appState.clearTeamSync()
            }
        } message: {
            Text(L("将移除本机设备凭证与同步状态；本地 Token 统计不会删除。"))
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isCommunitySyncEnrollmentCompatible {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("已连接社群榜服务器"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(isScreenshotRendering ? "https://••••" : displayServerURL)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: {
                            appState.settings.teamSyncEnabled
                                && TeamSyncCredentialStorageAvailability.isAvailable
                        },
                        set: { appState.setTeamSyncEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!TeamSyncCredentialStorageAvailability.isAvailable)
                }

                StatusLine(
                    symbol: syncStatusSymbol,
                    title: syncStatusTitle,
                    value: lastSyncText,
                    tint: syncStatusTint
                )

                if let omitted = appState.teamSyncState?.lastOmittedIncompleteBucketCount,
                   omitted > 0 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                        Text(LFormat("已跳过 %d 个无法安全同步的历史或分项桶", omitted))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        appState.syncTeamUsage(force: true)
                    } label: {
                        Text(appState.isTeamSyncing ? L("同步中") : L("立即同步"))
                            .font(.caption.weight(.heavy))
                            .frame(width: 88, height: 34)
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(
                        appState.isTeamSyncing
                            || !effectiveSyncEnabled
                            || !canManuallySync
                            || !TeamSyncCredentialStorageAvailability.isAvailable
                    )

                    Button {
                        guard let publicLeaderboardURL else { return }
                        NSWorkspace.shared.open(publicLeaderboardURL)
                    } label: {
                        Text(L("打开排行榜"))
                            .font(.caption.weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 104, height: 34)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(publicLeaderboardURL == nil)

                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Text(L("清除连接"))
                            .font(.caption.weight(.heavy))
                            .frame(width: 82, height: 34)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(appState.isTeamSyncing)
                }
            } else {
                if appState.teamSyncState?.isEnrolled == true {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("已有连接不属于当前固定社群服务器，请使用新的一次性注册码重新连接。"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                }

                Text(L("从专属接入页复制一次性注册码，粘贴后确认；注册码仅用于本次注册。"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let origin = appState.communityServerOrigin {
                    Text(isScreenshotRendering ? "https://••••" : origin.absoluteString)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                SecureField(L("一次性注册码"), text: $enrollmentToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(appState.isTeamSyncing || isScreenshotRendering)

                Button {
                    let token = enrollmentToken
                    enrollmentToken = ""
                    appState.enrollTeamSync(enrollmentToken: token)
                } label: {
                    Text(appState.isTeamSyncing ? L("连接中") : L("确认并开始同步"))
                        .font(.caption.weight(.heavy))
                        .frame(width: 120, height: 34)
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(
                    appState.isTeamSyncing
                        || enrollmentToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isScreenshotRendering
                        || appState.communityServerOrigin == nil
                        || !TeamSyncCredentialStorageAvailability.isAvailable
                )

                Text(L("确认后会立即上传当前可验证的历史日汇总，并持续在后台同步。"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.tokenInk.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var privacySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("只同步日汇总"))
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.tokenInk)
            TeamSyncPrivacyRow(text: L("连接后公开：昵称、Token、估算费用、工具、模型与日趋势"))
            TeamSyncPrivacyRow(text: L("仅上传日期、时区、工具、模型与 Token 数"))
            TeamSyncPrivacyRow(text: L("不上传主机名、序列号、本地路径、提示词、代码或会话正文"))
            TeamSyncPrivacyRow(text: L("设备密钥只存 macOS 钥匙串"))
            TeamSyncPrivacyRow(text: L("与生财 OpenToken 的配置和凭证完全独立"))
            TeamSyncPrivacyRow(text: L("当前账务日固定为 Asia/Shanghai，上报时不做时区重组"))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var displayServerURL: String {
        appState.communityServerOrigin?.absoluteString ?? ""
    }

    private var publicLeaderboardURL: URL? {
        return TeamSyncProtocol.publicLeaderboardURL(
            serverURL: appState.communityServerOrigin?.absoluteString ?? "",
            isEnrolled: appState.isCommunitySyncEnrollmentCompatible,
            isScreenshotRendering: isScreenshotRendering
        )
    }

    private var syncStatusTitle: String {
        if appState.isTeamSyncing { return L("同步中") }
        if appState.teamSyncState?.terminalReason == .credentials { return L("需要重新连接") }
        if appState.teamSyncState?.automaticRetryStopped == true { return L("自动重试已停止") }
        return effectiveSyncEnabled ? L("自动同步已开启") : L("自动同步已暂停")
    }

    private var syncStatusSymbol: String {
        if appState.isTeamSyncing { return "arrow.triangle.2.circlepath" }
        if appState.teamSyncState?.automaticRetryStopped == true { return "exclamationmark.lock.fill" }
        return effectiveSyncEnabled ? "checkmark.icloud.fill" : "pause.circle.fill"
    }

    private var syncStatusTint: Color {
        if appState.teamSyncState?.automaticRetryStopped == true { return .orange }
        return effectiveSyncEnabled ? .tokenGreen : .gray
    }

    private var effectiveSyncEnabled: Bool {
        appState.settings.teamSyncEnabled
            && appState.isCommunitySyncEnrollmentCompatible
            && TeamSyncCredentialStorageAvailability.isAvailable
    }

    private var canManuallySync: Bool {
        TeamSyncManualRetryPolicy.allowsForceRetry(
            automaticRetryStopped:
                appState.teamSyncState?.automaticRetryStopped == true,
            terminalReason: appState.teamSyncState?.terminalReason
        )
    }

    private var lastSyncText: String {
        guard let date = appState.teamSyncState?.lastSyncAt else {
            return L("尚未同步")
        }
        let formatter = DateFormatter()
        formatter.locale = TokenStepLocalization.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return LFormat("上次同步：%@", formatter.string(from: date))
    }
}

private struct TeamSyncPrivacyRow: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.tokenGreen)
                .padding(.top, 1)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
