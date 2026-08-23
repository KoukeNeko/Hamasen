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
