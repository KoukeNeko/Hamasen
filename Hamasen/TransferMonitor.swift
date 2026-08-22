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

        observe(manager.globalProgress(for: .downloading)) { [weak self] activity in
            self?.downloads = activity
        }
        observe(manager.globalProgress(for: .uploading)) { [weak self] activity in
            self?.uploads = activity
        }
    }

    func stop() {
        observations.removeAll()
        progresses.removeAll()
        downloads = Activity()
        uploads = Activity()
    }

    /// Reports one progress object's activity for as long as the monitor
    /// runs.
    ///
    /// What crosses out of the observation is an `Activity`, read on the
    /// notifying thread and sent onwards as a value. Handing over the
    /// `Progress` itself, or a key path into this class, would be sending a
    /// reference into another isolation domain.
    private func observe(
        _ progress: Progress,
        reporting report: @escaping @MainActor @Sendable (Activity) -> Void
    ) {
        progresses.append(progress)
        report(Self.activity(of: progress))
        // fractionCompleted moves on every chunk; the counts move with it, so
        // one observation covers the whole row.
        observations.append(
            progress.observe(\.fractionCompleted, options: [.new]) { observed, _ in
                let activity = Self.activity(of: observed)
                Task { @MainActor in report(activity) }
            }
        )
    }

    /// Read wherever the notification lands, which is not the main actor.
    nonisolated private static func activity(of progress: Progress) -> Activity {
        Activity(
            fractionCompleted: progress.fractionCompleted,
            completedBytes: progress.completedUnitCount,
            totalBytes: progress.totalUnitCount,
            fileCount: progress.fileTotalCount ?? 0
        )
    }
}
