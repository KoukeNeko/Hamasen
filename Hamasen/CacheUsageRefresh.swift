// Copyright 2026 KoukeNeko
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
