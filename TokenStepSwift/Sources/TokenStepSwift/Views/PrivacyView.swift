import SwiftUI

struct PrivacyView: View {
    var body: some View {
        VStack(spacing: 22) {
            TokenCard {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("本地优先"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    PrivacyRow(index: 1, title: L("只统计 token 数量"), description: L("用于计算今日 Token 消耗、历史趋势和消耗金额。"))
                    PrivacyRow(index: 2, title: L("不上传代码或对话"), description: L("只有主动连接社群榜后才同步日汇总；代码、提示词和会话正文始终留在本机。"))
                    PrivacyRow(index: 3, title: L("消耗金额仅供参考"), description: L("按本地价格表粗略估算，不等于真实账单。"))
                }
            }

            TokenCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("本地文件"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    FilePathRow(label: L("用量数据"), path: AppPaths.usageJSON.path)
                    FilePathRow(label: L("设置"), path: AppPaths.settingsJSON.path)
                    Text(L("加入社群榜需要单独连接和确认；未连接时不会上传日汇总。"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }
}

private struct PrivacyRow: View {
    var index: Int
    var title: String
    var description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(index)")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.tokenGreen)
                .frame(width: 34, height: 34)
                .background(Color.tokenGreen.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.tokenInk)
                Text(description)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FilePathRow: View {
    var label: String
    var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.76))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenTrack.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
