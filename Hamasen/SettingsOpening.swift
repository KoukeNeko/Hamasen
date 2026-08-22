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

import AppKit
import SwiftUI

extension OpenSettingsAction {
    /// Opens Settings and brings the app with it.
    ///
    /// Opening it alone orders the window within this app's own windows and
    /// stops there. Whenever Hamasen is not already the active app the window
    /// appears behind whatever the user was looking at — and it usually is
    /// not active, because the menu bar icon and Finder are the ways in and
    /// neither makes it so.
    @MainActor
    func raisingTheApp() {
        self()
        NSApp.activate(ignoringOtherApps: true)
    }
}
