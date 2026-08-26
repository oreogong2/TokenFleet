import AppKit
import Foundation
import SwiftUI

struct SettingsTeamSyncCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @State private var enrollmentToken = ""
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                connectionStatusCard
                syncFrequencyCard
            }
            publicPrivacyCard
            currentDeviceCard
            buildStatusNotice
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

    private var connectionStatusCard: some View {
        SettingsCard(title: L("连接状态"), symbol: "link.circle.fill", height: 176) {
            VStack(alignment: .leading, spacing: 0) {
                if appState.isCommunitySyncEnrollmentCompatible {
                    TeamSyncSettingRow(label: L("社群身份"), detail: appState.communityRank?.nickname ?? L("TokenFleet 成员"), value: L("已连接"), tint: .tokenGreenDark)
                    TeamSyncSettingRow(label: L("今天排名"), detail: rankPopulationText, value: rankText)
                    TeamSyncSettingRow(label: L("上次同步"), detail: L("设备凭据保存在系统钥匙串"), value: lastSyncCompactText)
                } else {
                    Text(L("从专属接入页复制一次性设备码；新增设备必须由管理员为既有成员签发。"))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField(L("一次性设备码"), text: $enrollmentToken)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isTeamSyncing || isScreenshotRendering)
                        .padding(.vertical, 8)
                    Button {
                        let token = enrollmentToken
                        enrollmentToken = ""
                        appState.enrollTeamSync(enrollmentToken: token)
                    } label: {
                        Text(appState.isTeamSyncing ? L("连接中") : L("确认并开始同步"))
                            .font(.system(size: 8, weight: .heavy))
                            .frame(width: 118, height: 30)
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(
                        appState.isTeamSyncing
                            || enrollmentToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isScreenshotRendering
                            || appState.communityServerOrigin == nil
                            || !TeamSyncCredentialStorageAvailability.isAvailable
                    )
                }
            }
        }
    }

    private var syncFrequencyCard: some View {
        SettingsCard(title: L("同步频率"), symbol: "arrow.triangle.2.circlepath", height: 176) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("自动同步")).font(.system(size: 9, weight: .heavy))
                        Text(L("本地数据更新后上传日聚合")).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScreenshotSafeToggle(isOn: Binding(
                        get: { effectiveSyncEnabled },
                        set: { appState.setTeamSyncEnabled($0) }
                    ))
                    .disabled(!appState.isCommunitySyncEnrollmentCompatible || !TeamSyncCredentialStorageAvailability.isAvailable)
                }
                .padding(.vertical, 8)
                TeamSyncSettingRow(label: L("失败重试"), detail: L("指数退避，不阻塞本地统计"), value: L("自动"))
                HStack(spacing: 7) {
                    Button {
                        appState.syncTeamUsage(force: true)
                    } label: {
                        Text(appState.isTeamSyncing ? L("同步中") : L("立即同步"))
                            .font(.system(size: 8, weight: .heavy)).frame(width: 76, height: 28)
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(appState.isTeamSyncing || !effectiveSyncEnabled || !canManuallySync)
                    Button {
                        appState.openCommunityLeaderboard(
                            isScreenshotRendering: isScreenshotRendering
                        )
                    } label: {
                        Text(L("打开排行榜")).font(.system(size: 8, weight: .heavy)).frame(width: 86, height: 28)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(publicLeaderboardURL == nil || appState.isOpeningCommunityLeaderboard)
                }
                .padding(.top, 7)
            }
        }
    }

    private var publicPrivacyCard: some View {
        SettingsCard(title: L("公开与隐私"), symbol: "lock.shield.fill", height: 150) {
            VStack(alignment: .leading, spacing: 9) {
                TeamSyncSettingRow(
                    label: L("公开榜状态"),
                    detail: L("是否公开由社群管理员控制；本机不会伪造权限开关"),
                    value: appState.communityRank?.publicProfileEnabled == true ? L("已加入") : L("未公开"),
                    tint: .tokenGreenDark
                )
                HStack(spacing: 6) {
                    TeamSyncPrivacyChip(text: L("只同步日汇总"))
                    TeamSyncPrivacyChip(text: L("不上传提示词与回复"))
                    TeamSyncPrivacyChip(text: L("不上传代码与路径"))
                }
                HStack {
                    Text(L("清除连接后保留本机 Token 历史。"))
                        .font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { showsClearConfirmation = true } label: {
                        Text(L("清除连接")).font(.system(size: 8, weight: .heavy)).frame(width: 74, height: 28)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(!appState.isCommunitySyncEnrollmentCompatible || appState.isTeamSyncing)
                }
            }
        }
    }

    private var currentDeviceCard: some View {
        SettingsCard(title: L("当前设备连接"), symbol: "laptopcomputer.and.iphone", height: 154) {
            VStack(alignment: .leading, spacing: 0) {
                TeamSyncSettingRow(label: L("这台设备"), detail: L("凭据安全保存在本机，不展示原始设备码"), value: appState.isCommunitySyncEnrollmentCompatible ? L("已连接") : L("未连接"), tint: .tokenGreenDark)
                TeamSyncSettingRow(label: L("添加另一台设备"), detail: L("向管理员领取新的 60 分钟单次码；多台设备归入同一昵称"), value: L("不影响本机"))
                TeamSyncSettingRow(label: L("普通用户权限"), detail: L("不能自行生成或补发设备码"), value: L("管理员签发"))
            }
        }
    }

    @ViewBuilder
    private var buildStatusNotice: some View {
        if !TeamSyncCredentialStorageAvailability.isAvailable || appState.communityServerOrigin == nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(!TeamSyncCredentialStorageAvailability.isAvailable
                     ? L("当前源码构建未启用安全凭据存储，社群同步保持关闭。")
                     : L("当前源码构建未配置有效社群服务器，社群同步不可用。"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tokenInk.opacity(0.72))
                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let error = appState.teamSyncActionError ?? appState.teamSyncState?.lastError, !error.isEmpty {
            Text(error)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var rankText: String {
        appState.communityRank?.rank.map { "#\($0)" } ?? L("暂无")
    }

    private var rankPopulationText: String {
        appState.communityRank.map { LFormat("%d 名参榜用户", $0.totalEntries) } ?? L("等待读取")
    }

    private var lastSyncCompactText: String {
        guard let date = appState.teamSyncState?.lastSyncAt else { return L("尚未同步") }
        let formatter = DateFormatter()
        formatter.locale = TokenStepLocalization.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
                    ScreenshotSafeToggle(isOn: Binding(
                        get: {
                            appState.settings.teamSyncEnabled
                                && TeamSyncCredentialStorageAvailability.isAvailable
                        },
                        set: { appState.setTeamSyncEnabled($0) }
                    ))
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
                        appState.openCommunityLeaderboard(
                            isScreenshotRendering: isScreenshotRendering
                        )
                    } label: {
                        Text(L("打开排行榜"))
                            .font(.caption.weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 104, height: 34)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(publicLeaderboardURL == nil || appState.isOpeningCommunityLeaderboard)

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
            TeamSyncPrivacyRow(text: L("与第三方服务的配置和凭证完全独立"))
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

private struct TeamSyncSettingRow: View {
    var label: String
    var detail: String
    var value: String
    var tint: Color = .tokenInk

    var body: some View {
        HStack(spacing: 10) {
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
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }
}

private struct TeamSyncPrivacyChip: View {
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 6, weight: .black))
            Text(text).font(.system(size: 7, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.74)
        }
        .foregroundStyle(Color.tokenGreenDark)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color.tokenMint.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
