import FileProvider
import Foundation
import HamasenCore
import Observation

/// What is being transferred right now, as the system reports it.
///
/// The provider does not have to count anything: the system keeps a running
/// progress per domain for uploads and for downloads, summing whatever is in
/// flight. Both objects have to be retained to keep receiving updates, and
/// they are updated on the main queue, which is where this is observed.
@MainActor
@Observable
final class TransferMonitor {
    /// One direction of transfer, flattened into what a view needs.
    struct Activity: Equatable {
        var fractionCompleted: Double = 1
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var fileCount: Int = 0

        /// The system leaves the progress finished and at 1 when nothing is
        /// happening, which is how idle is told from a transfer that has just
        /// reached the end.
        var isActive: Bool { fileCount > 0 && fractionCompleted < 1 }
    }

    private(set) var downloads = Activity()
    private(set) var uploads = Activity()

    var isTransferring: Bool { downloads.isActive || uploads.isActive }

    /// Retained for as long as the monitor runs: releasing them stops the
    /// updates.
    private var progresses: [Progress] = []
    private var observations: [NSKeyValueObservation] = []

    /// Starts reporting for the domain, or stops if it is not registered —
    /// there is nothing to transfer without a mount.
    func refreshDomainBinding() {
        stop()
        guard let manager = try? FinderDomain.manager() else { return }

        observe(manager.globalProgress(for: .downloading), into: \.downloads)
        observe(manager.globalProgress(for: .uploading), into: \.uploads)
    }

    func stop() {
        observations.removeAll()
        progresses.removeAll()
        downloads = Activity()
        uploads = Activity()
    }

    private func observe(_ progress: Progress, into keyPath: ReferenceWritableKeyPath<TransferMonitor, Activity>) {
        progresses.append(progress)
        apply(progress, to: keyPath)
        // fractionCompleted moves on every chunk; the counts move with it, so
        // one observation covers the whole row.
        observations.append(
            progress.observe(\.fractionCompleted, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in self?.apply(observed, to: keyPath) }
            }
        )
    }

    private func apply(_ progress: Progress, to keyPath: ReferenceWritableKeyPath<TransferMonitor, Activity>) {
        self[keyPath: keyPath] = Activity(
            fractionCompleted: progress.fractionCompleted,
            completedBytes: progress.completedUnitCount,
            totalBytes: progress.totalUnitCount,
            fileCount: progress.fileTotalCount ?? 0
        )
    }
}
