import SwiftUI

struct TodayBreakdownCard: View {
    var title: String
    var rows: [TodayBreakdownRow]
    var maxRows: Int = 3
    @State private var isExpanded = false

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Spacer()
                    Text(LFormat("%d 项", rows.count))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.tokenGreenDark)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.tokenMint.opacity(0.24), in: Capsule())
                }

                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                } else {
                    VStack(spacing: 14) {
                        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                            TodayBreakdownRowView(
                                row: row,
                                color: row.color ?? rowColor(index: index)
                            )
                        }
                    }

                    if rows.count > maxRows {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text(isExpanded
                                    ? L("收起，只看 Top 3")
                                    : LFormat("展开全部 %d 项", rows.count))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                Spacer()
                            }
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                            .frame(height: 34)
                            .background(Color.tokenMint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visibleRows: [TodayBreakdownRow] {
        isExpanded ? rows : Array(rows.prefix(maxRows))
    }

    private func rowColor(index: Int) -> Color {
        switch index {
        case 0: return .tokenGreenDark
        case 1: return .tokenGreen
        case 2: return TokenStepThemeRuntime.palette.activity3.color
        default: return TokenStepThemeRuntime.palette.activity2.color
        }
    }
}

struct TodayBreakdownRow: Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    var percent: Double
    var color: Color?
}

private struct TodayBreakdownRowView: View {
    var row: TodayBreakdownRow
    var color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(row.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.tokenInk.opacity(0.78))
                .lineLimit(1)
                .frame(width: 138, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tokenTrack)
                    if row.percent > 0 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(5, proxy.size.width * min(max(row.percent, 0), 100) / 100))
                    }
                }
            }
            .frame(height: 10)

            Text("\(TokenStepFormat.tokens(row.tokens, compact: true)) · \(TokenStepFormat.percent(row.percent))")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
                .frame(width: 126, alignment: .trailing)
        }
        .frame(height: 30)
    }
}
