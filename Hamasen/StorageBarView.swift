import HamasenCore
import SwiftUI

/// How much of this Mac a server is using, in the shape macOS uses for disks.
///
/// Two segments rather than one: what the user pinned cannot be reclaimed by
/// the allowance, so a bar that did not separate it would suggest space is
/// recoverable when it is not.
struct StorageBarView: View {
    let usage: CacheUsage
    let allowance: Int64?

    private static let barHeight: CGFloat = 10
    /// A segment thinner than this reads as a rendering artefact, so a
    /// non-zero amount is never drawn as nothing.
    private static let minimumVisibleWidth: CGFloat = 3

    /// What the bar is drawn against: the allowance when there is one, and
    /// otherwise the amount in use, which then always fills it.
    private var capacity: Int64 {
        max(allowance ?? usage.totalBytes, 1)
    }

    private var isOverAllowance: Bool {
        guard let allowance else { return false }
        return usage.totalBytes > allowance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            legend
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                segment(usage.pinnedBytes, of: geometry.size.width, color: .accentColor)
                segment(
                    usage.evictableBytes,
                    of: geometry.size.width,
                    color: isOverAllowance ? .orange : Color.accentColor.opacity(0.45)
                )
                Rectangle().fill(.quaternary)
            }
            .clipShape(.rect(cornerRadius: Self.barHeight / 2))
        }
        .frame(height: Self.barHeight)
    }

    private func segment(_ bytes: Int64, of totalWidth: CGFloat, color: Color) -> some View {
        let width = totalWidth * CGFloat(bytes) / CGFloat(capacity)
        return Rectangle()
            .fill(color)
            .frame(width: bytes > 0 ? max(width, Self.minimumVisibleWidth) : 0)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            if usage.pinnedBytes > 0 {
                label("保留", bytes: usage.pinnedBytes, color: .accentColor)
            }
            label(
                "快取",
                bytes: usage.evictableBytes,
                color: isOverAllowance ? .orange : Color.accentColor.opacity(0.45)
            )
            Spacer()
            Text(capacityDescription)
                .foregroundStyle(isOverAllowance ? .orange : .secondary)
        }
        .font(.caption)
    }

    private func label(_ title: LocalizedStringKey, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
            Text(Self.formatted(bytes)).foregroundStyle(.secondary)
        }
    }

    private var capacityDescription: String {
        guard let allowance else { return Self.formatted(usage.totalBytes) }
        return "\(Self.formatted(usage.totalBytes)) / \(Self.formatted(allowance))"
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
