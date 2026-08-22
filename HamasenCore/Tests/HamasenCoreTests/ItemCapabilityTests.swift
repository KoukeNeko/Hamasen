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
import Testing

@Suite("File Provider item capabilities")
struct ItemCapabilityTests {
    /// The extension spells the eviction capability as its raw bit so the
    /// app builds without a deprecation warning on every file that touches
    /// it. That trades a symbol for a number, and this is where the number is
    /// checked against the symbol — a test is allowed to name a deprecated
    /// thing, since nothing ships it.
    @Test("驅逐權限的位元值與系統常數相符")
    func pinsTheEvictionCapabilityBit() {
        let legacyEvictionPermission = NSFileProviderItemCapabilities(rawValue: 1 << 6)
        #expect(legacyEvictionPermission == .allowsEvicting)
    }
}
