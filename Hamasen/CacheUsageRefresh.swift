import SwiftUI

extension View {
    /// Keeps the local-usage figures current for as long as a view showing
    /// them is on screen.
    ///
    /// Content lands on this Mac by files being opened in Finder, which
    /// happens while the view is already up: measuring once on appear would
    /// leave the figures stale for as long as the window stays open.
    ///
    /// - Parameter restartingOn: an identity that starts the refresh over
    ///   when it changes, for a view that reuses itself across subjects.
    func refreshingCacheUsage(
        from model: ServerListModel,
        restartingOn id: AnyHashable = 0
    ) -> some View {
        task(id: id) {
            while !Task.isCancelled {
                await model.cache.refreshUsage()
                try? await Task.sleep(for: CacheSupervisor.refreshInterval)
            }
        }
    }
}
