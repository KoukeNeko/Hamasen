import HamasenCore
import SwiftUI

/// How much of this Mac a server is using, in the shape System Settings uses
/// for a disk: a headline with the totals, a segmented bar whose remaining
/// space carries its own figure, and a legend underneath.
///
/// Two segments rather than one: what the user pinned cannot be reclaimed by
/// the allowance, so a bar that did not separate it would suggest space is
/// recoverable when it is not.
struct StorageBarView: View {
    let usage: CacheUsage
    let allowance: Int64?

    private static let barHeight: CGFloat = 22
    private static let cornerRadius: CGFloat = 5
    /// A segment thinner than this reads as a rendering artefact, so a
    /// non-zero amount is never drawn as nothing.
    private static let minimumVisibleWidth: CGFloat = 4
    /// The free area only gets a figure when there is room to print one.
    private static let minimumWidthForLabel: CGFloat = 56

    private var isOverAllowance: Bool {
        guard let allowance else { return false }
        return usage.totalBytes > allowance
    }

    /// What the bar is drawn against: the allowance when there is one, and
    /// otherwise the amount in use, which then fills it completely.
    private var capacity: Int64 {
        max(allowance ?? usage.totalBytes, 1)
    }

    private var freeBytes: Int64 {
        max(capacity - usage.totalBytes, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            bar
            legend
        }
    }

    private var headline: some View {
        HStack {
            Text("本機使用量")
            Spacer()
            Text(headlineTotals)
                .foregroundStyle(isOverAllowance ? .orange : .secondary)
        }
        .font(.subheadline)
    }

    private var headlineTotals: String {
        guard let allowance else { return Self.formatted(usage.totalBytes) }
        return "\(Self.formatted(usage.totalBytes)) / \(Self.formatted(allowance))"
    }

    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 1) {
                segment(usage.pinnedBytes, of: width, color: .accentColor)
                segment(usage.evictableBytes, of: width, color: isOverAllowance ? .orange : .teal)
                freeArea(width: Self.width(of: freeBytes, capacity: capacity, in: width))
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .frame(height: Self.barHeight)
    }

    private func segment(_ bytes: Int64, of totalWidth: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: bytes > 0
                ? max(Self.width(of: bytes, capacity: capacity, in: totalWidth), Self.minimumVisibleWidth)
                : 0)
    }

    /// The unused remainder, labelled inside itself the way the system's own
    /// bar labels free space.
    private func freeArea(width: CGFloat) -> some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if freeBytes > 0, width >= Self.minimumWidthForLabel {
                    Text(Self.formatted(freeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            if usage.pinnedBytes > 0 {
                label("保留", bytes: usage.pinnedBytes, color: .accentColor)
            }
            label("快取", bytes: usage.evictableBytes, color: isOverAllowance ? .orange : .teal)
            Spacer()
        }
        .font(.caption)
    }

    private func label(_ title: LocalizedStringKey, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Text(Self.formatted(bytes)).foregroundStyle(.secondary)
        }
    }

    private static func width(of bytes: Int64, capacity: Int64, in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(bytes) / CGFloat(capacity)
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
