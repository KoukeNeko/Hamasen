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

import FileProvider
import Foundation
import Testing
@testable import HamasenCore

/// Adding a domain that already exists updates its display name and hidden
/// state and nothing else, so a capability declared later never reaches it.
/// Replacing the domain is the only way, and it costs the replica — which is
/// why deciding when to do it is worth pinning.
@Suite("FinderDomain capabilities")
struct FinderDomainCapabilityTests {
    /// Someone whose domain predates search. Without this the feature is
    /// permanently unreachable for every existing install.
    @Test
    func aDomainFromBeforeTheCapabilityIsReplaced() {
        #expect(FinderDomain.needsReplacing(storedGeneration: 0))
        #expect(FinderDomain.needsReplacing(storedGeneration: 1))
    }

    /// The generation is written after a successful add, so a domain already
    /// carrying the current capabilities must be left alone. Replacing it
    /// every launch would throw away every cached file every launch.
    @Test
    func aCurrentDomainIsLeftAlone() {
        #expect(FinderDomain.needsReplacing(storedGeneration: 2) == false)
    }

    /// A newer generation means the defaults were written by a build ahead of
    /// this one. Replacing then would be a downgrade fighting an upgrade.
    @Test
    func aDomainFromANewerBuildIsLeftAlone() {
        #expect(FinderDomain.needsReplacing(storedGeneration: 99) == false)
    }
}

/// Unmounting the last server used to remove the domain, which kept unsynced
/// edits in the location's folder, and mounting again added the domain back.
/// The new domain took that folder over: its leftovers came back as local
/// items the extension refused, shadowing the servers' own folders. The
/// domain is now hidden and shown instead, and only an outdated domain is
/// ever removed.
@Suite("FinderDomain registration")
struct FinderDomainRegistrationTests {
    private let visible = FinderDomain.makeDomain(isHidden: false)
    private let hidden = FinderDomain.makeDomain(isHidden: true)

    private func step(
        _ registered: NSFileProviderDomain?, generation: Int = 2, mounted: Bool
    ) -> FinderDomain.RegistrationStep {
        FinderDomain.registrationStep(
            registered: registered, storedGeneration: generation, hasMountedServers: mounted)
    }

    /// The incident: removing on the way out is what left the folder behind.
    /// An outdated domain is not replaced on the way out either, since
    /// replacing removes.
    @Test
    func unmountingTheLastServerHidesTheDomain() {
        for generation in [0, 1, 2] {
            #expect(step(visible, generation: generation, mounted: false) == .setHidden(true))
        }
    }

    /// The same domain comes back, so there is no folder for a new one to
    /// take over. Leaving it alone because its capabilities are current
    /// would keep the location out of Finder for good.
    @Test
    func mountingAgainShowsTheHiddenDomain() {
        #expect(step(hidden, mounted: true) == .setHidden(false))
    }

    /// Search still reaches someone whose domain predates it, once something
    /// is mounted and the capability is wanted.
    @Test
    func anOutdatedDomainIsReplacedOnlyWhileSomethingIsMounted() {
        #expect(step(hidden, generation: 1, mounted: true) == .replace)
        #expect(step(visible, generation: 1, mounted: true) == .replace)
        #expect(step(hidden, generation: 1, mounted: false) == .leave)
    }

    /// A Mac that never mounted anything, or whose domain an older build
    /// removed, gets a domain only when there is something to show.
    @Test
    func aDomainIsCreatedOnlyForSomethingToShow() {
        #expect(step(nil, mounted: false) == .leave)
        #expect(step(nil, generation: 0, mounted: true) == .create)
        #expect(step(nil, generation: 2, mounted: true) == .create)
    }

    /// Mounting a second server, or launching with the same set, must not
    /// touch the registration at all.
    @Test
    func aDomainAlreadyInPlaceIsLeftAlone() {
        #expect(step(visible, mounted: true) == .leave)
        #expect(step(hidden, mounted: false) == .leave)
    }
}
