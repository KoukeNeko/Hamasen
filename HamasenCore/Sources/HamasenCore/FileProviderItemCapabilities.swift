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

extension NSFileProviderItemCapabilities {
    /// `allowsEvicting` was deprecated once content policies were introduced,
    /// but existing materializations still need its capability bit before
    /// `NSFileProviderManager.evictItem` will accept them. Keep that public
    /// bit without referring to the deprecated spelling; `contentPolicy`
    /// remains the source of truth for when content should be downloaded or
    /// retained.
    public static let legacyEvictionPermission = Self(rawValue: 1 << 6)
}
