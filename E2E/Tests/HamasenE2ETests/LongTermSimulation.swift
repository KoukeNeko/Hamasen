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

import Darwin
import Foundation
import Testing
@testable import HamasenCore

/// Five years of one person's use of every kind of connection, compressed
/// into a run of minutes.
///
/// The calendar is simulated; the servers, the network and the clients are
/// real. Each simulated day some files are made, edited, read, renamed,
/// moved and deleted, and the same is applied to a record of what each
/// server should hold. Each month a server restarts, an upload is cut off
/// halfway and the network has a bad day; each year the passwords, the SSH
/// host key, the certificates and the cloud sign-ins change. At the end of
/// every month each server is read back and compared with the record, the
/// change detection is compared with what actually changed, and the local
/// copies are cleaned against the simulated date as auto-clean would.
///
/// What it is looking for is what only time finds: state that grows without
/// bound, a session that never recovers, a rename that loses a file on the
/// thousandth try, a leftover that stops a folder being deleted years later.
@Suite("Five years of use", .enabled(if: E2E.isAvailable && SoakSettings.isRequested), .serialized)
struct LongTermSimulation {
    @Test("模擬五年長期使用")
    func fiveYears() async throws {
        let settings = SoakSettings.fromEnvironment()
        let simulation = try await Simulation(settings: settings)
        let report = await simulation.run()
        let written = try report.write(to: E2E.runDirectory)
        print("Soak report: \(written.path)")

        for finding in report.findings {
            Issue.record(Comment(rawValue: finding))
        }
        // A client that leaks a descriptor per session has hundreds more by
        // the end; a few dozen is sessions that happen to be open.
        if let first = report.months.first, let last = report.months.last {
            #expect(last.openFiles - first.openFiles < 64,
                    "open files went from \(first.openFiles) to \(last.openFiles)")
            #expect(last.residentMegabytes < first.residentMegabytes * 2 + 256,
                    "memory went from \(first.residentMegabytes) MB to \(last.residentMegabytes) MB")
        }
    }
}

// MARK: - Settings

struct SoakSettings: Codable, Sendable {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["HAMASEN_E2E_SOAK"] == "1"
    }

    var years = 5
    /// Days with activity in each month, spread across it. Auto-clean runs
    /// on every day regardless, as the app's sweep does.
    var activeDaysPerMonth = 6
    var operationsPerDay = 5
    var lanes = Lane.allCases.map(\.rawValue)
    var seed: UInt64 = 20_260_101
    var unusedDays = AppSettings.defaultAutoCleanUnusedDays
    /// Scaled down from the app's 10 GB with the files, so the ceiling is
    /// reached and has to be kept.
    var localCopyLimitBytes: Int64 = 3_000_000
    /// Past this many files a lane deletes more than it makes, so the tree
    /// stays a size an audit can read back every month.
    var maximumFiles = 120

    static func fromEnvironment() -> SoakSettings {
        let environment = ProcessInfo.processInfo.environment
        var settings = SoakSettings()
        if let years = environment["HAMASEN_E2E_SOAK_YEARS"].flatMap(Int.init) { settings.years = years }
        if let days = environment["HAMASEN_E2E_SOAK_DAYS"].flatMap(Int.init) { settings.activeDaysPerMonth = days }
        if let operations = environment["HAMASEN_E2E_SOAK_OPERATIONS"].flatMap(Int.init) {
            settings.operationsPerDay = operations
        }
        if let seed = environment["HAMASEN_E2E_SOAK_SEED"].flatMap(UInt64.init) { settings.seed = seed }
        if let lanes = environment["HAMASEN_E2E_SOAK_LANES"], !lanes.isEmpty {
            settings.lanes = lanes.split(separator: ",").map(String.init).filter { Lane(rawValue: $0) != nil }
        }
        return settings
    }
}

// MARK: - The run

/// The simulated calendar and everything that happens on it.
private actor Simulation {
    private static let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    private static let day: TimeInterval = 86_400

    private let settings: SoakSettings
    private let runs: [LaneRun]
    private let usage: ItemUsageStore
    private let activity: ActivityStore
    private let directory: URL
    private var report: SoakReport
    private var rotatedServices: Set<String> = []
    private let startedAt = Date()
    /// What count-temp found before the run: what earlier runs stranded
    /// elsewhere on the servers, which is not this run's to report.
    private var temporaryFilesBefore: [String: Int] = [:]

    init(settings: SoakSettings) async throws {
        self.settings = settings
        let runID = String(UUID().uuidString.prefix(6)).lowercased()
        directory = E2E.runDirectory.appending(path: "soak-\(runID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let usage = ItemUsageStore(fileURL: directory.appending(path: "item-usage.json"))
        self.usage = usage
        activity = ActivityStore(fileURL: directory.appending(path: "activity.json"))
        report = SoakReport(settings: settings, startedAt: Date())

        var runs: [LaneRun] = []
        for (index, name) in settings.lanes.enumerated() {
            guard let lane = Lane(rawValue: name) else { continue }
            runs.append(try LaneRun(
                lane: lane, runID: runID, seed: settings.seed &+ UInt64(index) &* 7_919,
                directory: directory.appending(path: name), usage: usage, settings: settings))
        }
        self.runs = runs
        try await Toxiproxy.reset()
        // A short token lifetime is set on the cloud mock for this run, so
        // the sessions renew throughout rather than once.
        for run in runs where run.lane.oauthProvider != nil {
            try await run.clients.signIn()
        }
        for run in runs {
            try await run.prepare()
        }
        temporaryFilesBefore = await countTemporaryFiles()
    }

    func run() async -> SoakReport {
        let months = settings.years * 12
        for month in 0..<months {
            let monthStart = Self.start.addingTimeInterval(Double(month) * 30.44 * Self.day)
            let activeDays = Set((0..<settings.activeDaysPerMonth).map {
                Int(Double($0) * 30.0 / Double(settings.activeDaysPerMonth))
            })
            let badNetworkDay = activeDays.sorted()[month % activeDays.count]

            for dayIndex in 0..<30 {
                let date = monthStart.addingTimeInterval(Double(dayIndex) * Self.day + 9 * 3_600)
                if activeDays.contains(dayIndex) {
                    if dayIndex == badNetworkDay { await badNetwork(on: true) }
                    let operations = settings.operationsPerDay
                    await withTaskGroup(of: Void.self) { group in
                        for run in runs {
                            group.addTask { await run.day(date: date, operations: operations) }
                        }
                    }
                    if dayIndex == badNetworkDay { await badNetwork(on: false) }
                    if month == 0, dayIndex == 0 {
                        for run in runs { run.pinSome() }
                    }
                }
                await autoClean(at: date)
            }

            let monthEnd = monthStart.addingTimeInterval(29 * Self.day + 18 * 3_600)
            await restartServer(month: month)
            await interruptUpload(month: month, date: monthEnd)
            if month % 12 == 6 {
                for run in runs { await run.uploadLargeFile(date: monthEnd) }
            }
            if month % 12 == 11 {
                await rotateCredentials(year: month / 12 + 1)
            }
            for run in runs {
                await run.audit(month: month, readsEveryFile: month % 12 == 11)
            }
            await sample(month: month, date: monthEnd)
        }
        await finish()
        return report
    }

    // MARK: Events

    /// A day of latency and fragmented packets on every proxied link. Nothing
    /// is expected to fail; everything just takes longer.
    private func badNetwork(on: Bool) async {
        let proxies = Set(runs.filter(\.clients.viaProxy).compactMap(\.lane.proxy))
        do {
            if on {
                for proxy in proxies.sorted() {
                    try await Toxiproxy.add(.latency(milliseconds: 120), to: proxy, name: "soak-latency")
                    try await Toxiproxy.add(.slicer(averageBytes: 512), to: proxy, name: "soak-slicer")
                }
            } else {
                try await Toxiproxy.reset()
            }
        } catch {
            report.findings.append("toxiproxy: \(error)")
        }
    }

    /// One server a month goes down and comes back, as an update or a power
    /// cut does. The sessions to it die with it, and the next operation on
    /// each has to notice and connect again.
    private func restartServer(month: Int) async {
        let services = Array(Set(runs.filter { $0.lane.oauthProvider == nil }.map(\.lane.service))).sorted()
        guard !services.isEmpty else { return }
        let service = services[month % services.count]
        do {
            try await ServerControl.restart(service)
            report.restarts += 1
        } catch {
            report.findings.append("month \(month): restarting \(service): \(error)")
        }
    }

    /// One proxied lane a month has an upload cut off partway.
    private func interruptUpload(month: Int, date: Date) async {
        let proxied = runs.filter(\.clients.viaProxy)
        guard !proxied.isEmpty else { return }
        await proxied[month % proxied.count].interruptedUpload(date: date, month: month)
    }

    /// What changes once a year: each server's password, the SSH host key,
    /// the TLS certificates, and every cloud sign-in.
    private func rotateCredentials(year: Int) async {
        let byService = Dictionary(grouping: runs.filter(\.lane.hasPassword), by: \.lane.service)
        for (service, lanes) in byService.sorted(by: { $0.key < $1.key }) {
            let password = "hamasen-y\(year)-\(UUID().uuidString.prefix(4))"
            do {
                try await ServerControl.exec(service, "set-password", password)
                rotatedServices.insert(service)
            } catch {
                report.findings.append("year \(year): set-password on \(service): \(error)")
                continue
            }
            for run in lanes { await run.followPasswordChange(to: password, year: year) }
        }
        for run in runs {
            switch run.lane {
            case .sftp: await run.followHostKeyChange(year: year)
            case .ftps, .webdavs: await run.followCertificateChange(year: year)
            case .dropbox, .oneDrive, .googleDrive: await run.followRevocation(year: year)
            default: break
            }
        }
    }

    /// The app's shared policy, over every connection's local copies at
    /// once, on the simulated date.
    private func autoClean(at date: Date) async {
        let policy = AutoCleanPolicy(unusedDays: settings.unusedDays, totalLimitBytes: settings.localCopyLimitBytes)
        do {
            let present = Set(runs.flatMap(\.copyIdentifiers))
            let recorded = try usage.reconcile(present: present, at: date)
            let items = runs.flatMap { $0.cachedItems(usage: recorded) }
            let pinned = Set(runs.flatMap(\.pinnedIdentifiers))
            let planned = CacheEvictionPlan.itemsToClean(
                from: items, policy: policy, pinned: pinned, now: date, limit: 10_000)
            if let problem = Self.checkCleaning(items: items, planned: planned, pinned: pinned, policy: policy, now: date) {
                report.findings.append("auto-clean on \(date.formatted(.iso8601.year().month().day())): \(problem)")
            }
            let dropped = Set(planned)
            for run in runs { run.dropCopies(dropped) }
            report.copiesCleaned += planned.count
        } catch {
            report.findings.append("auto-clean: \(error)")
        }
    }

    /// What auto-clean promises, checked against what it chose.
    static func checkCleaning(
        items: [CachedItem], planned: [String], pinned: Set<String>, policy: AutoCleanPolicy, now: Date
    ) -> String? {
        let dropped = Set(planned)
        if !dropped.isDisjoint(with: pinned) {
            return "dropped a pinned copy"
        }
        let cutoff = now.addingTimeInterval(-Double(policy.unusedDays) * day)
        let kept = items.filter { !dropped.contains($0.identifier) && !pinned.contains($0.identifier) }
        if let stale = kept.first(where: { ($0.lastUsedAt ?? .distantFuture) < cutoff }) {
            return "kept \(stale.identifier), unused since \(stale.lastUsedAt!)"
        }
        if let ceiling = policy.totalLimitBytes {
            let total = items.filter { !dropped.contains($0.identifier) }.reduce(Int64(0)) { $0 + $1.byteCount }
            if total > ceiling, !kept.isEmpty {
                return "left \(total) bytes over a \(ceiling)-byte ceiling with unpinned copies still there"
            }
            // Dropped for room, stalest first: nothing kept is staler than
            // anything dropped while still in its idle period.
            let droppedForRoom = items.filter { dropped.contains($0.identifier) && ($0.lastUsedAt ?? .distantPast) >= cutoff }
            if let newestDropped = droppedForRoom.compactMap(\.lastUsedAt).max(),
               let stalestKept = kept.compactMap(\.lastUsedAt).min(),
               stalestKept < newestDropped {
                return "dropped a copy used \(newestDropped) and kept one used \(stalestKept)"
            }
        }
        return nil
    }

    /// Upload temporaries on each server with a count-temp command, by
    /// compose service.
    private func countTemporaryFiles() async -> [String: Int] {
        var counts: [String: Int] = [:]
        let services = Set(runs.filter { $0.lane.hasPassword }.map(\.lane.service))
        for service in services.sorted() {
            if let output = try? await ServerControl.exec(service, "count-temp"),
               let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                counts[service] = count
            }
        }
        return counts
    }

    private func sample(month: Int, date: Date) async {
        var temporaryFiles = await countTemporaryFiles()
        for (service, before) in temporaryFilesBefore {
            temporaryFiles[service]? -= before
        }
        // Measured as the app measures: after forgetting the copies gone
        // since the last pass.
        let usageEntries = (try? usage.reconcile(present: Set(runs.flatMap(\.copyIdentifiers)), at: date).count) ?? -1
        let activityBytes = Self.size(of: directory.appending(path: "activity.json"))
        report.months.append(MonthSample(
            month: month + 1,
            simulatedDate: date,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            openFiles: Resources.openFileDescriptors(),
            residentMegabytes: Double(Resources.residentBytes()) / 1_048_576,
            localCopies: runs.reduce(0) { $0 + $1.copies.count },
            localCopyBytes: runs.reduce(Int64(0)) { $0 + $1.copyBytes },
            usageEntries: usageEntries,
            usageFileBytes: Self.size(of: directory.appending(path: "item-usage.json")),
            snapshotBytes: runs.reduce(0) { $0 + $1.snapshotBytes },
            activityFileBytes: activityBytes,
            temporaryFiles: temporaryFiles,
            filesOnServers: runs.reduce(0) { $0 + $1.files.count }))

        // The activity log is written by every transfer; it has to stay the
        // size of the last few dozen, however many there have been.
        for run in runs {
            let outcomes = run.takeTransferOutcomes()
            do {
                try activity.update { snapshot in
                    for outcome in outcomes {
                        snapshot.completed.insert(CompletedTransfer(
                            id: UUID(), serverID: run.clients.id, path: outcome.path, direction: outcome.direction,
                            totalBytes: outcome.bytes, finishedAt: date), at: 0)
                    }
                }
                try activity.recordHealth(ServerHealth(state: .reachable, since: date), for: run.clients.id)
            } catch {
                report.findings.append("activity log: \(error)")
            }
        }
        if activityBytes > 64_000 {
            report.findings.append("month \(month + 1): activity log is \(activityBytes) bytes")
        }
        if usageEntries > runs.reduce(0, { $0 + $1.copies.count }) {
            report.findings.append("month \(month + 1): usage record keeps \(usageEntries) entries for fewer copies")
        }
    }

    private func finish() async {
        for service in rotatedServices.sorted() {
            do {
                try await ServerControl.exec(service, "set-password", E2E.password)
            } catch {
                report.findings.append("restoring the password on \(service): \(error)")
                continue
            }
            // The lanes still hold the year's password, which the clean-up
            // below would be refused with: WebDAV signs every request, and
            // its server restarts to take the change.
            for run in runs where run.lane.service == service {
                run.clients.credentials.currentPassword = E2E.password
                await run.mount.discard()
            }
        }
        try? await Toxiproxy.reset()
        for run in runs {
            await run.removeEverything()
            report.lanes.append(await run.summary())
            report.findings.append(contentsOf: run.findings)
        }
        report.finishedAt = Date()
    }

    private static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - One lane

/// One connection over the five years: its client, the record of what its
/// server should hold, and the local copies the system would keep for it.
///
/// Used by one task at a time — a day's work, then the month's events — so
/// it carries no lock.
private final class LaneRun: @unchecked Sendable {
    struct FileSpec: Equatable, Codable, Sendable {
        let size: Int
        let seed: UInt64
        var data: Data { Fixtures.bytes(size, seed: seed) }
        var hash: String { Fixtures.sha256(data) }
    }

    struct TransferOutcome {
        let path: String
        let direction: TransferDirection
        let bytes: Int64
    }

    enum Write: Sendable {
        case upload(String, FileSpec)
        case createDirectory(String)
        case deleteFile(String)
        case deleteDirectory(String)
        case move(String, String)
    }

    private static let words = ["報告", "日本語メモ", "한국어 문서", "notes", "photo", "budget 2026", "emoji 😀",
                                "a+b&c", "draft", "Résumé", "UPPER lower"]
    private static let extensions = ["txt", "pdf", "bin", "jpg", "docx", "tar.gz"]
    private static let maximumFindings = 25

    let lane: Lane
    let clients: LaneClients
    let mount: Mount
    /// The lane's folder on the server, as an absolute path.
    let root: String
    private let settings: SoakSettings
    private var rng: SeededGenerator
    private var counter = 0

    /// What the server should hold, by path relative to `root`.
    private(set) var files: [String: FileSpec] = [:]
    private var directories: Set<String> = [RemotePath.root]
    /// Files with a copy on this Mac, and their sizes.
    private(set) var copies: [String: Int] = [:]
    private var pinned: Set<String> = []
    private var transferOutcomes: [TransferOutcome] = []

    /// The app's record of when each copy was last wanted, shared by every
    /// lane as it is by every connection.
    private let usage: ItemUsageStore
    private let snapshots: RemoteDirectorySnapshotStore
    private let snapshotDirectory: URL
    /// Each directory's entries at the last audit: a file's spec, or nil
    /// for a folder.
    private var audited: [String: [String: FileSpec?]] = [:]

    private(set) var findings: [String] = []
    private var findingCount = 0
    private var operations: [String: Int] = [:]
    private var bytesUploaded: Int64 = 0
    private var bytesDownloaded: Int64 = 0
    private var recovered = 0
    private var interruptedUploads = 0
    private var rotations = 0

    init(lane: Lane, runID: String, seed: UInt64, directory: URL, usage: ItemUsageStore, settings: SoakSettings) throws {
        self.lane = lane
        self.usage = usage
        self.settings = settings
        clients = LaneClients(lane: lane)
        mount = Mount(clients)
        root = "/soak-\(runID)-\(lane.rawValue)"
        rng = SeededGenerator(seed: seed)
        snapshotDirectory = directory.appending(path: "snapshots")
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        snapshots = RemoteDirectorySnapshotStore(directoryURL: snapshotDirectory)
    }

    func prepare() async throws {
        try await mount.write { [root] in try await $0.createDirectory(at: root) }
    }

    // MARK: Paths

    private func absolute(_ relative: String) -> String {
        relative == RemotePath.root ? root : root + relative
    }

    private func relative(_ absolute: String) -> String {
        let rest = String(absolute.dropFirst(root.count))
        return (rest.isEmpty ? RemotePath.root : rest).precomposedStringWithCanonicalMapping
    }

    private func identifier(_ relative: String) -> String {
        "srv:\(clients.id.uuidString):\(relative)"
    }

    private func isTaken(_ relative: String) -> Bool {
        files[relative] != nil || directories.contains(relative)
    }

    private func isInside(_ path: String, _ folder: String) -> Bool {
        folder == RemotePath.root || path.hasPrefix(folder + "/")
    }

    private func depth(_ relative: String) -> Int {
        relative.split(separator: "/").count
    }

    private func newName() -> String {
        counter += 1
        let word = Self.words.randomElement(using: &rng)!
        let ext = Self.extensions.randomElement(using: &rng)!
        return "\(word)-\(counter).\(ext)".precomposedStringWithCanonicalMapping
    }

    private func newFolderName() -> String {
        counter += 1
        return "folder \(counter)"
    }

    /// Mostly small, sometimes a photo, now and then a few megabytes.
    private func newSpec(differingFrom old: FileSpec? = nil) -> FileSpec {
        var size: Int
        repeat {
            let roll = Int.random(in: 0..<100, using: &rng)
            if roll < 70 {
                size = Int.random(in: 0...16_384, using: &rng)
            } else if roll < 95 {
                size = Int.random(in: 16_385...262_144, using: &rng)
            } else {
                size = Int.random(in: 262_145...3_000_000, using: &rng)
            }
        } while size == old?.size
        return FileSpec(size: size, seed: rng.next())
    }

    private func randomFile() -> String? {
        files.keys.sorted().randomElement(using: &rng)
    }

    private func randomFolder(maximumDepth: Int = 3) -> String {
        directories.filter { depth($0) < maximumDepth }.sorted().randomElement(using: &rng) ?? RemotePath.root
    }

    // MARK: A day

    func day(date: Date, operations count: Int) async {
        for _ in 0..<count {
            await step(date: date.addingTimeInterval(Double(Int.random(in: 0..<36_000, using: &rng))))
        }
    }

    private func step(date: Date) async {
        var weights: [(String, Int)] = [
            ("create", 20), ("overwrite", 14), ("read", 16), ("readRange", 8), ("reopen", 10),
            ("rename", 8), ("move", 7), ("delete", 8), ("mkdir", 4), ("rmdir", 2), ("moveFolder", 2),
        ]
        if files.count > settings.maximumFiles {
            weights = weights.map { $0.0 == "delete" ? ("delete", 40) : $0.0 == "create" ? ("create", 4) : $0 }
        }
        let total = weights.reduce(0) { $0 + $1.1 }
        var roll = Int.random(in: 0..<total, using: &rng)
        var kind = "create"
        for (name, weight) in weights {
            if roll < weight { kind = name; break }
            roll -= weight
        }
        if files.isEmpty, kind != "mkdir" { kind = "create" }
        operations[kind, default: 0] += 1

        switch kind {
        case "create":
            let path = RemotePath.join(randomFolder(maximumDepth: 4), newName())
            await perform(.upload(path, newSpec()), date: date)
        case "overwrite":
            guard let path = randomFile() else { return }
            await perform(.upload(path, newSpec(differingFrom: files[path])), date: date)
        case "read":
            guard let path = randomFile() else { return }
            await read(path, date: date)
        case "readRange":
            guard let path = randomFile() else { return }
            await readRange(path)
        case "reopen":
            // A copy already here opens without the network; only its use
            // is noted.
            guard let path = copies.keys.sorted().randomElement(using: &rng) else { return }
            noteUse(path, at: date)
        case "rename":
            guard let path = randomFile() else { return }
            let target = RemotePath.join(RemotePath.parent(of: path), newName())
            await perform(.move(path, target), date: date)
        case "move":
            guard let path = randomFile() else { return }
            let parent = RemotePath.parent(of: path)
            let candidates = directories.filter { $0 != parent && depth($0) < 4 }.sorted()
            guard let folder = candidates.randomElement(using: &rng) else { return }
            let target = RemotePath.join(folder, RemotePath.name(of: path))
            guard !isTaken(target) else { return }
            await perform(.move(path, target), date: date)
        case "delete":
            guard let path = randomFile() else { return }
            await perform(.deleteFile(path), date: date)
        case "mkdir":
            let folder = RemotePath.join(randomFolder(), newFolderName())
            await perform(.createDirectory(folder), date: date)
        case "rmdir":
            guard let folder = directories.filter({ $0 != RemotePath.root }).sorted().randomElement(using: &rng)
            else { return }
            await perform(.deleteDirectory(folder), date: date)
        case "moveFolder":
            guard let folder = directories.filter({ $0 != RemotePath.root }).sorted().randomElement(using: &rng)
            else { return }
            let candidates = directories.filter {
                !isInside($0, folder) && $0 != folder && $0 != RemotePath.parent(of: folder) && depth($0) < 3
            }.sorted()
            guard let destination = candidates.randomElement(using: &rng) else { return }
            let target = RemotePath.join(destination, RemotePath.name(of: folder))
            guard !isTaken(target) else { return }
            await perform(.move(folder, target), date: date)
        default:
            break
        }
    }

    // MARK: Reads

    private func read(_ path: String, date: Date) async {
        guard let spec = files[path] else { return }
        let target = absolute(path)
        do {
            let hash = try await mount.read { try await Fixtures.downloadHash(target, with: $0) }
            bytesDownloaded += Int64(spec.size)
            transferOutcomes.append(TransferOutcome(path: path, direction: .download, bytes: Int64(spec.size)))
            if hash != spec.hash {
                finding("\(path) reads back different from what was written")
                await forget(path)
                return
            }
            copies[path] = spec.size
            do {
                try usage.recordDownload(of: identifier(path), at: date)
            } catch {
                finding("recording a download: \(error)")
            }
        } catch {
            finding("reading \(path): \(error)")
        }
    }

    private func readRange(_ path: String) async {
        guard let spec = files[path], spec.size > 0 else { return }
        let offset = Int.random(in: 0..<spec.size, using: &rng)
        let length = Int.random(in: 1...min(65_536, spec.size - offset + 10), using: &rng)
        let target = absolute(path)
        do {
            let slice = try await mount.read {
                try await $0.downloadRange(at: target, offset: Int64(offset), length: length)
            }
            let expected = spec.data.subdata(in: offset..<min(spec.size, offset + length))
            if slice != expected {
                finding("\(path) bytes \(offset)+\(length) read back wrong (\(slice.count) bytes)")
            }
        } catch {
            finding("reading \(path) from \(offset): \(error)")
        }
    }

    private func noteUse(_ path: String, at date: Date) {
        do {
            try usage.recordUse(of: identifier(path), at: date)
        } catch {
            finding("recording a use: \(error)")
        }
    }

    // MARK: Writes

    /// Sends a write the way the system does: when the session died under
    /// it, the server is asked what happened, and the write is sent again on
    /// a new session if it did not.
    private func perform(_ write: Write, date: Date, expectingInterruption: Bool = false) async {
        do {
            try await send(write)
            commit(write, date: date)
        } catch {
            guard expectingInterruption || Mount.isConnectionFailure(error) else {
                finding("\(describe(write)): \(error)")
                await resynchronize(write)
                return
            }
            recovered += 1
            switch await outcome(of: write) {
            case true?:
                commit(write, date: date)
            case false?:
                do {
                    try await send(write)
                    commit(write, date: date)
                } catch {
                    finding("\(describe(write)), sent again after the session was lost: \(error)")
                    await resynchronize(write)
                }
            case nil:
                finding("\(describe(write)) was cut off and left neither the old state nor the new one")
                await resynchronize(write)
            }
        }
    }

    private func send(_ write: Write) async throws {
        switch write {
        case .upload(let path, let spec):
            let target = absolute(path)
            let data = spec.data
            _ = try await mount.write { try await Fixtures.upload(data, to: target, with: $0) }
            bytesUploaded += Int64(spec.size)
            transferOutcomes.append(TransferOutcome(path: path, direction: .upload, bytes: Int64(spec.size)))
        case .createDirectory(let path):
            let target = absolute(path)
            try await mount.write { try await $0.createDirectory(at: target) }
        case .deleteFile(let path):
            let target = absolute(path)
            try await mount.write { try await $0.deleteFile(at: target) }
        case .deleteDirectory(let path):
            let target = absolute(path)
            try await mount.write { try await $0.deleteDirectory(at: target) }
        case .move(let source, let destination):
            let from = absolute(source), to = absolute(destination)
            try await mount.write { try await $0.moveItem(from: from, to: to) }
        }
    }

    /// Whether a write that failed took effect: true if it did, false if
    /// the server is as it was, nil if it is neither.
    private func outcome(of write: Write) async -> Bool? {
        switch write {
        case .upload(let path, let spec):
            let target = absolute(path)
            let hash = try? await mount.read { try await Fixtures.downloadHash(target, with: $0) }
            if hash == spec.hash { return true }
            if hash == files[path]?.hash { return false }
            return hash == nil && files[path] == nil ? false : nil
        case .createDirectory(let path):
            return await exists(path)
        case .deleteFile(let path), .deleteDirectory(let path):
            return await exists(path).map { !$0 }
        case .move(let source, let destination):
            switch (await exists(source), await exists(destination)) {
            case (false?, true?): return true
            case (true?, false?): return false
            default: return nil
            }
        }
    }

    private func exists(_ path: String) async -> Bool? {
        let target = absolute(path)
        do {
            _ = try await mount.read { try await $0.itemInfo(at: target) }
            return true
        } catch RemoteFileServiceError.itemNotFound {
            return false
        } catch {
            return nil
        }
    }

    /// Applies a write that happened to the record and to this Mac's copies.
    private func commit(_ write: Write, date: Date) {
        switch write {
        case .upload(let path, let spec):
            files[path] = spec
            // Written from here, so the copy here is the new content.
            copies[path] = spec.size
            noteUse(path, at: date)
        case .createDirectory(let path):
            directories.insert(path)
        case .deleteFile(let path):
            files[path] = nil
            copies[path] = nil
            pinned.remove(path)
        case .deleteDirectory(let path):
            for file in files.keys where isInside(file, path) { files[file] = nil }
            for copy in copies.keys where isInside(copy, path) { copies[copy] = nil }
            pinned = pinned.filter { !isInside($0, path) }
            directories = directories.filter { $0 != path && !isInside($0, path) }
        case .move(let source, let destination):
            func moved(_ path: String) -> String {
                path == source ? destination : destination + path.dropFirst(source.count)
            }
            let affected: (String) -> Bool = { $0 == source || self.isInside($0, source) }
            files = Dictionary(uniqueKeysWithValues: files.map { (affected($0.key) ? moved($0.key) : $0.key, $0.value) })
            copies = Dictionary(uniqueKeysWithValues: copies.map { (affected($0.key) ? moved($0.key) : $0.key, $0.value) })
            pinned = Set(pinned.map { affected($0) ? moved($0) : $0 })
            directories = Set(directories.map { affected($0) ? moved($0) : $0 })
        }
    }

    private func describe(_ write: Write) -> String {
        switch write {
        case .upload(let path, let spec): return "uploading \(spec.size) bytes to \(path)"
        case .createDirectory(let path): return "creating \(path)"
        case .deleteFile(let path): return "deleting \(path)"
        case .deleteDirectory(let path): return "deleting folder \(path)"
        case .move(let source, let destination): return "moving \(source) to \(destination)"
        }
    }

    /// After a finding, brings the record and the server back into line by
    /// removing what the write touched, so one failure is reported once
    /// rather than in every audit after it.
    private func resynchronize(_ write: Write) async {
        switch write {
        case .upload(let path, _), .deleteFile(let path), .createDirectory(let path), .deleteDirectory(let path):
            await forget(path)
        case .move(let source, let destination):
            await forget(source)
            await forget(destination)
        }
    }

    private func forget(_ path: String) async {
        let target = absolute(path)
        if directories.contains(path) {
            _ = try? await mount.write { try await $0.deleteDirectory(at: target) }
            commit(.deleteDirectory(path), date: Date())
        } else {
            _ = try? await mount.write { try await $0.deleteFile(at: target) }
            commit(.deleteFile(path), date: Date())
        }
    }

    // MARK: Month-end events

    func pinSome() {
        for path in copies.keys.sorted().prefix(2) { pinned.insert(path) }
    }

    /// An upload of a few megabytes cut off by a dropped connection.
    func interruptedUpload(date: Date, month: Int) async {
        guard let proxy = lane.proxy else { return }
        let path = randomFile() ?? RemotePath.join(RemotePath.root, newName())
        let spec = FileSpec(size: 2_500_000 + Int.random(in: 0..<100_000, using: &rng), seed: rng.next())
        let write = Write.upload(path, spec)
        let wasCut: Bool
        do {
            wasCut = try await Toxiproxy.cutting(proxy, after: 1.5, slowedBy: lane.uploadSlowing) { [self] in
                try await E2E.withDeadline(120, "upload being cut off") { [self] in try await send(write) }
            }
        } catch {
            finding("month \(month + 1): toxiproxy: \(error)")
            try? await Toxiproxy.reset()
            return
        }
        try? await Toxiproxy.reset()
        if wasCut {
            interruptedUploads += 1
            await mount.discard()
            switch await outcome(of: write) {
            case true?:
                commit(write, date: date)
            case false?:
                await perform(write, date: date)
            case nil:
                finding("month \(month + 1): an upload cut off left \(path) neither as it was nor as it was going to be")
                await forget(path)
            }
        } else {
            commit(write, date: date)
        }
    }

    /// Above the multipart thresholds of S3 and the cloud APIs.
    func uploadLargeFile(date: Date) async {
        let path = RemotePath.join(RemotePath.root, newName())
        await perform(.upload(path, FileSpec(size: 12_000_000 + Int.random(in: 0..<1_000, using: &rng), seed: rng.next())),
                      date: date)
    }

    func followPasswordChange(to password: String, year: Int) async {
        rotations += 1
        await mount.discard()
        do {
            _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
            finding("year \(year): still signed in with the old password")
        } catch RemoteFileServiceError.authenticationFailed {
        } catch {
            finding("year \(year): the old password was reported as \(error), not as a sign-in failure")
        }
        clients.credentials.currentPassword = password
        await requireWorking("year \(year): with the new password")
    }

    func followHostKeyChange(year: Int) async {
        rotations += 1
        do {
            try await ServerControl.exec(lane.service, "rotate-hostkey")
        } catch {
            finding("year \(year): rotate-hostkey: \(error)")
            return
        }
        await mount.discard()
        do {
            _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
            finding("year \(year): connected after the host key changed")
        } catch RemoteFileServiceError.hostKeyChanged {
        } catch {
            finding("year \(year): a changed host key was reported as \(error)")
        }
        do {
            try KnownHostsStore(fileURL: clients.credentials.knownHostsURL)
                .forget(endpoint: KnownHosts.endpoint(host: clients.config.host, port: clients.config.port))
        } catch {
            finding("year \(year): clearing the host key: \(error)")
        }
        await requireWorking("year \(year): after accepting the new host key")
    }

    func followCertificateChange(year: Int) async {
        rotations += 1
        do {
            try await ServerControl.exec(lane.service, "rotate-cert")
        } catch {
            finding("year \(year): rotate-cert: \(error)")
            return
        }
        await mount.discard()
        await requireWorking("year \(year): after the certificate was reissued")
    }

    func followRevocation(year: Int) async {
        guard let provider = lane.oauthProvider else { return }
        rotations += 1
        do {
            try await CloudMock.revoke(provider)
        } catch {
            finding("year \(year): revoking: \(error)")
            return
        }
        do {
            _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
            finding("year \(year): still signed in after the sign-in was revoked")
        } catch RemoteFileServiceError.authenticationFailed {
        } catch {
            finding("year \(year): a revoked sign-in was reported as \(error)")
        }
        do {
            try await clients.signIn()
        } catch {
            finding("year \(year): signing in again: \(error)")
            return
        }
        await mount.discard()
        await requireWorking("year \(year): after signing in again")
    }

    private func requireWorking(_ what: String) async {
        do {
            _ = try await mount.read { try await $0.listDirectory(at: RemotePath.root) }
        } catch {
            finding("\(what): \(error)")
        }
    }

    // MARK: Audit

    /// Reads the lane's whole tree back and compares it with the record:
    /// every path, every size, and the content of a sample of files — or of
    /// every file, once a year. Then compares what the change detection
    /// reports with what changed since the last audit.
    func audit(month: Int, readsEveryFile: Bool) async {
        let label = "month \(month + 1)"
        let items: [RemoteItem]
        do {
            items = try await mount.read { [root] in try await Fixtures.walk(root, with: $0) }
        } catch {
            finding("\(label): listing the tree: \(error)")
            return
        }

        var seenFiles: [String: Int64] = [:]
        var seenDirectories: Set<String> = [RemotePath.root]
        var byDirectory: [String: [RemoteItem]] = [:]
        for item in items {
            let path = relative(item.path)
            byDirectory[RemotePath.parent(of: path), default: []].append(item)
            if item.isDirectory { seenDirectories.insert(path) } else { seenFiles[path] = item.size }
        }

        for (path, spec) in files.sorted(by: { $0.key < $1.key }) {
            guard let size = seenFiles[path] else {
                finding("\(label): \(path) is missing from the server")
                files[path] = nil
                copies[path] = nil
                continue
            }
            if size != Int64(spec.size) {
                finding("\(label): \(path) is \(size) bytes on the server, \(spec.size) expected")
                await forget(path)
            }
        }
        for path in seenFiles.keys.sorted() where files[path] == nil && !findingsMention(path) {
            finding("\(label): \(path) is on the server but was never left there")
        }
        for path in directories.subtracting(seenDirectories).sorted() {
            finding("\(label): folder \(path) is missing from the server")
            directories.remove(path)
        }
        for path in seenDirectories.subtracting(directories).sorted() {
            finding("\(label): folder \(path) is on the server but was never left there")
        }

        let toRead = readsEveryFile
            ? files.keys.sorted()
            : Array(files.keys.sorted().shuffled(using: &rng).prefix(15))
        for path in toRead {
            guard let spec = files[path] else { continue }
            let target = absolute(path)
            do {
                let hash = try await mount.read { try await Fixtures.downloadHash(target, with: $0) }
                if hash != spec.hash {
                    finding("\(label): \(path) has different content from what was written")
                    await forget(path)
                }
            } catch {
                finding("\(label): reading \(path) back: \(error)")
            }
        }

        checkChangeDetection(byDirectory: byDirectory, label: label)
    }

    private func findingsMention(_ path: String) -> Bool {
        findings.contains { $0.contains(path) }
    }

    /// The record the app polls against, given each directory's listing, has
    /// to report exactly what was added and removed since the last audit,
    /// and among files, an edit that changed the size, without reporting a
    /// file nobody touched.
    private func checkChangeDetection(byDirectory: [String: [RemoteItem]], label: String) {
        var current: [String: [String: FileSpec?]] = [:]
        for directory in directories { current[directory] = [:] }
        for directory in directories where directory != RemotePath.root {
            current[RemotePath.parent(of: directory), default: [:]][RemotePath.name(of: directory)] = .some(nil)
        }
        for (path, spec) in files {
            current[RemotePath.parent(of: path), default: [:]][RemotePath.name(of: path)] = .some(spec)
        }

        for directory in directories.sorted() {
            let listing = byDirectory[directory] ?? []
            let change: RemoteDirectorySnapshot.Change
            do {
                change = try snapshots.record(listing, serverID: clients.id, directoryPath: absolute(directory))
            } catch {
                finding("\(label): recording \(directory): \(error)")
                continue
            }
            guard let before = audited[directory] else { continue }
            let now = current[directory] ?? [:]
            let nfc: ([String]) -> Set<String> = { Set($0.map(\.precomposedStringWithCanonicalMapping)) }
            let added = Set(now.keys).subtracting(before.keys)
            let removed = Set(before.keys).subtracting(now.keys)
            if nfc(change.addedNames) != added {
                finding("\(label): \(directory) reported added \(change.addedNames.sorted()), expected \(added.sorted())")
            }
            if nfc(change.removedNames) != removed {
                finding("\(label): \(directory) reported removed \(change.removedNames.sorted()), expected \(removed.sorted())")
            }
            var edited: Set<String> = []
            var resized: Set<String> = []
            for (name, spec) in now {
                guard let spec, let old = before[name] ?? nil, old != spec else { continue }
                edited.insert(name)
                if old.size != spec.size { resized.insert(name) }
            }
            let reportedFiles = nfc(change.updatedNames).filter { now[$0] != nil && now[$0]! != nil }
            if !reportedFiles.isSubset(of: edited) {
                finding("\(label): \(directory) reported \(reportedFiles.subtracting(edited).sorted()) changed, which nobody edited")
            }
            if !resized.isSubset(of: reportedFiles) {
                finding("\(label): \(directory) missed edits to \(resized.subtracting(reportedFiles).sorted())")
            }
        }
        audited = current
    }

    // MARK: Local copies

    var copyIdentifiers: [String] { copies.keys.map(identifier) }
    var pinnedIdentifiers: [String] { pinned.map(identifier) }
    var copyBytes: Int64 { copies.values.reduce(Int64(0)) { $0 + Int64($1) } }

    func cachedItems(usage recorded: [String: ItemUsageStore.Usage]) -> [CachedItem] {
        copies.map { path, size in
            CachedItem(identifier: identifier(path), serverID: clients.id, byteCount: Int64(size),
                       modifiedAt: nil, lastUsedAt: recorded[identifier(path)]?.latest)
        }
    }

    func dropCopies(_ identifiers: Set<String>) {
        for path in copies.keys where identifiers.contains(identifier(path)) { copies[path] = nil }
    }

    var snapshotBytes: Int {
        let enumerator = FileManager.default.enumerator(at: snapshotDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func takeTransferOutcomes() -> [TransferOutcome] {
        defer { transferOutcomes.removeAll() }
        return transferOutcomes
    }

    // MARK: End

    func removeEverything() async {
        do {
            try await mount.write { [root] in try await $0.deleteDirectory(at: root) }
        } catch {
            finding("removing the lane's folder at the end: \(error)")
        }
        await mount.close()
    }

    func summary() async -> LaneSummary {
        LaneSummary(
            lane: lane.rawValue, operations: operations, bytesUploaded: bytesUploaded,
            bytesDownloaded: bytesDownloaded, recoveredFailures: recovered,
            sessionsOpened: await mount.sessionsOpened, interruptedUploads: interruptedUploads,
            rotations: rotations, filesAtEnd: files.count, findings: findingCount)
    }

    private func finding(_ text: String) {
        findingCount += 1
        if findings.count < Self.maximumFindings {
            findings.append("[\(lane.rawValue)] \(text)")
        } else if findings.count == Self.maximumFindings {
            findings.append("[\(lane.rawValue)] … further findings counted, not listed")
        }
    }
}

// MARK: - Measuring

private enum Resources {
    static func openFileDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

// MARK: - Report

struct LaneSummary: Codable, Sendable {
    let lane: String
    let operations: [String: Int]
    let bytesUploaded: Int64
    let bytesDownloaded: Int64
    let recoveredFailures: Int
    let sessionsOpened: Int
    let interruptedUploads: Int
    let rotations: Int
    let filesAtEnd: Int
    let findings: Int
}

struct MonthSample: Codable, Sendable {
    let month: Int
    let simulatedDate: Date
    let elapsedSeconds: Double
    let openFiles: Int
    let residentMegabytes: Double
    let localCopies: Int
    let localCopyBytes: Int64
    let usageEntries: Int
    let usageFileBytes: Int
    let snapshotBytes: Int
    let activityFileBytes: Int
    /// Uploads this run has stranded on each server, by compose service.
    let temporaryFiles: [String: Int]
    let filesOnServers: Int
}

struct SoakReport: Codable, Sendable {
    let settings: SoakSettings
    let startedAt: Date
    var finishedAt: Date?
    var lanes: [LaneSummary] = []
    var months: [MonthSample] = []
    var restarts = 0
    var copiesCleaned = 0
    var findings: [String] = []

    init(settings: SoakSettings, startedAt: Date) {
        self.settings = settings
        self.startedAt = startedAt
    }

    /// Writes the report as JSON and as Markdown, returning the Markdown.
    func write(to directory: URL) throws -> URL {
        let stamp = startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appending(path: "soak-\(stamp).json"))
        let markdown = directory.appending(path: "soak-\(stamp).md")
        try Data(self.markdown.utf8).write(to: markdown)
        return markdown
    }

    var markdown: String {
        var text = "# Soak: \(settings.years) simulated years\n\n"
        let elapsed = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        text += "Ran \(Int(elapsed / 60)) min, seed \(settings.seed), \(settings.activeDaysPerMonth) active days a month, "
        text += "\(settings.operationsPerDay) operations a day per lane. "
        text += "\(restarts) server restarts, \(copiesCleaned) local copies cleaned.\n\n"
        text += "**\(findings.isEmpty ? "No findings" : "\(findings.count) findings")**\n\n"
        text += "| Lane | Operations | Uploaded | Downloaded | Recovered | Sessions | Cut uploads | Rotations | Files | Findings |\n"
        text += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for lane in lanes {
            let operations = lane.operations.values.reduce(0, +)
            text += "| \(lane.lane) | \(operations) | \(Self.megabytes(lane.bytesUploaded)) | "
            text += "\(Self.megabytes(lane.bytesDownloaded)) | \(lane.recoveredFailures) | \(lane.sessionsOpened) | "
            text += "\(lane.interruptedUploads) | \(lane.rotations) | \(lane.filesAtEnd) | \(lane.findings) |\n"
        }
        text += "\n## Over time\n\n"
        text += "| Month | Elapsed | Open files | Memory | Local copies | Usage record | Snapshots | Activity log | Stranded uploads |\n"
        text += "|---:|---:|---:|---:|---:|---:|---:|---:|---|\n"
        for sample in months where sample.month == 1 || sample.month % 6 == 0 {
            let stranded = sample.temporaryFiles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            text += "| \(sample.month) | \(Int(sample.elapsedSeconds)) s | \(sample.openFiles) | "
            text += "\(Int(sample.residentMegabytes)) MB | \(sample.localCopies) (\(Self.megabytes(sample.localCopyBytes))) | "
            text += "\(sample.usageEntries) (\(sample.usageFileBytes / 1_024) KB) | \(sample.snapshotBytes / 1_024) KB | "
            text += "\(sample.activityFileBytes / 1_024) KB | \(stranded) |\n"
        }
        if !findings.isEmpty {
            text += "\n## Findings\n\n"
            for finding in findings { text += "- \(finding)\n" }
        }
        return text
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
