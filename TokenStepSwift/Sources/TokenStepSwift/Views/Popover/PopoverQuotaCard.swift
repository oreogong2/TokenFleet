import SwiftUI

struct PopoverQuotaCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L("Agent 剩余额度"))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.tokenInk)
                    Spacer()
                    if appState.isRefreshingCodexQuota {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                    } else if let fetchedAt = appState.codexQuota.fetchedAt {
                        Text(quotaFetchedText(fetchedAt))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    } else if let fetchedAt = appState.claudeQuota.fetchedAt {
                        Text(quotaFetchedText(fetchedAt))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.hasAnyQuota {
                    HStack(alignment: .top, spacing: 7) {
                        if appState.codexQuota.isAvailable {
                            quotaSection(title: "Codex", quota: appState.codexQuota)
                        }
                        if appState.claudeQuota.isAvailable {
                            quotaSection(title: "Claude Code", quota: appState.claudeQuota)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.tokenGreen)
                            .frame(width: 28, height: 28)
                            .background(Color.tokenMint.opacity(0.22), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("暂未读取到 Agent 额度"))
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(Color.tokenInk.opacity(0.76))
                            Text(L("打开并登录 Codex / Claude Code 后会自动显示。"))
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tokenMint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tokenGreen.opacity(0.14)))
        .padding(.horizontal, 20)
        .padding(.bottom, 13)
    }

    private func quotaSection(title: String, quota: CodexQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.tokenInk.opacity(0.76))
            VStack(spacing: 6) {
                quotaRow(quota.fiveHour, fallbackTitle: L("5 小时"))
                quotaRow(quota.sevenDay, fallbackTitle: L("7 天"))
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func quotaRow(_ window: CodexQuotaWindow?, fallbackTitle: String) -> some View {
        HStack(spacing: 10) {
            Text(window?.title ?? fallbackTitle)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Color.tokenInk.opacity(0.72))
                .frame(width: 38, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(window.map { LFormat("剩余 %@", TokenStepFormat.percent($0.remainingPercent)) } ?? L("等待同步"))
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(window == nil ? .secondary : Color.tokenInk.opacity(0.82))
                    Spacer()
                    Text(window.map { quotaResetText($0.resetsAt) } ?? L("等待重置"))
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.tokenGreen.opacity(0.10))
                        if let window {
                            Capsule()
                                .fill(Color.tokenGreen)
                                .frame(width: max(5, proxy.size.width * window.remainingPercent / 100))
                        }
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func quotaResetText(_ date: Date?) -> String {
        guard let date else { return L("等待重置") }
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        if seconds < 60 {
            return L("即将重置")
        }
        if seconds < 3_600 {
            return LFormat("%d 分后重置", max(1, seconds / 60))
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return LFormat("约 %d:%02d 后重置", hours, minutes)
        }
        let days = max(1, Int(ceil(Double(seconds) / 86_400)))
        return LFormat("%d 天后重置", days)
    }

    private func quotaFetchedText(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
        if seconds < 60 {
            return L("刚刚")
        }
        return LFormat("%d 分钟前", max(1, seconds / 60))
    }
}
