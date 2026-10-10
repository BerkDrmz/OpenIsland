import Foundation
import Testing
import UniformTypeIdentifiers
@testable import IslandCore

@Suite("Feedback and file integrity regressions")
struct FeedbackRegressionTests {
    static let filenames = [
        "rapor.pdf", "foto.png", "foto.jpg", "foto.jpeg", "archive.zip", "disk.dmg",
        "film.mov", "film.mp4", "image.psd", "report.docx", "sheet.xlsx", "code.swift",
        "data.json", "backup.tar.gz", "project.backup.zip", "README", ".hidden", ".config.json",
        "İğdır şüphe ÇÖĞÜ.pdf", "REPORT.PDF", String(repeating: "long", count: 50) + ".pdf",
    ]

    @Test(arguments: filenames)
    func copiesPreserveNameSourcePathAndBytes(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(name)
        let bytes = Data([0, 255, 37, 80, 68, 70, 13, 10])
        try bytes.write(to: source)
        let cache = root.appendingPathComponent("cache")
        let first = try ShelfImportRules.copyRepresentation(at: source, suggestedFilename: name, into: cache)
        let second = try ShelfImportRules.copyRepresentation(at: source, suggestedFilename: name, into: cache)
        #expect(first != second)
        for url in [source, first, second] {
            #expect(url.lastPathComponent == name)
            #expect(url.pathExtension == source.pathExtension)
            #expect(try Data(contentsOf: url) == bytes)
        }
        try FileManager.default.removeItem(at: first)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
    }

    @Test func parallelImportsDoNotOverwriteEachOther() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rapor.pdf")
        try Data([1, 2, 3]).write(to: source)
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<20 {
                group.addTask { try ShelfImportRules.copyRepresentation(at: source, suggestedFilename: "rapor.pdf",
                                                                       into: root.appendingPathComponent("cache")) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(Set(results).count == 20)
        for url in results { #expect(try Data(contentsOf: url) == Data([1, 2, 3])) }
    }

    @Test func mismatchedRepresentationIsRejectedRatherThanRenamed() {
        #expect(ShelfImportRules.fileRepresentationType([UTType.png.identifier], suggestedFilename: "foto.heic") == nil)
        #expect(ShelfImportRules.fileRepresentationType([UTType.png.identifier, UTType.jpeg.identifier],
                                                       suggestedFilename: "foto.jpeg") == UTType.jpeg.identifier)
        #expect(ShelfImportRules.fileRepresentationType([UTType.png.identifier, UTType.data.identifier],
                                                       suggestedFilename: "foto.heic") == UTType.data.identifier)
        let temp = URL(fileURLWithPath: "/tmp/archive.tar.gz")
        #expect(ShelfImportRules.preservedFilename(suggested: nil, temporaryURL: temp) == "archive.tar.gz")
        #expect(ShelfImportRules.preservedFilename(suggested: "../bad.pdf", temporaryURL: temp) == nil)
        #expect(ShelfImportRules.preservedFilename(suggested: "", temporaryURL: temp) == nil)
    }

    @Test func initialConnectionsDuplicatesAndRapidReconnect() {
        var state = BluetoothConnectionState()
        state.seed(["device-a"])
        let initial = state.connect("device-a")
        let fresh = state.connect("device-b")
        let duplicate = state.connect("device-b")
        #expect(!initial)
        #expect(fresh)
        #expect(!duplicate)
        state.disconnect("device-b")
        let reconnected = state.connect("device-b")
        let empty = state.connect("")
        #expect(reconnected)
        #expect(!empty)
        #expect(BluetoothConnectionState.displayName(" \n ") == "Bluetooth cihazı")
        #expect(BluetoothConnectionState.displayName("Berk’s AirPods Pro") == "Berk’s AirPods Pro")
    }

    @Test func alreadyConnectedBluetoothRouteSelectionIsNotConnection() {
        let device = AudioDeviceInfo(id: 7, name: "Headset", kind: .headphones, isBluetooth: true)
        #expect(AudioOutputRules.notice(previous: [device], current: [device], previousDefault: 1,
                                        currentDefault: 7, recentlyAnnounced: []) == nil)
    }

    @Test func unlockQueuesConnectionAndReturnsToMedia() throws {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.mediaPlaybackChanged(isPlaying: true))
        let unlock = machine.send(.noticeRequested(.unlocked))
        let connection = IslandNotice.audioOutput(name: "Headset", kind: .headphones, connected: true)
        machine.send(.noticeRequested(connection))
        #expect(machine.notice == .unlocked)
        machine.send(.pointerEntered) // unlock must still finish in a bounded time
        guard case let .schedule(.noticeDismiss, token, _)? = unlock.first else {
            Issue.record("Missing unlock timer"); return
        }
        let next = machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.notice == connection)
        guard case let .schedule(.noticeDismiss, connectionToken, _)? = next.first else {
            Issue.record("Missing connection timer"); return
        }
        machine.send(.pointerExited)
        machine.send(.timerFired(.noticeDismiss, token: token)) // stale unlock completion
        #expect(machine.notice == connection)
        machine.send(.timerFired(.noticeDismiss, token: connectionToken))
        #expect(machine.presentation == .compact(.media))
    }

    @Test func lockCancelsDeferredConnectionAndExpandedTabIsPreserved() {
        var machine = IslandMachine()
        machine.send(.noticeRequested(.unlocked))
        machine.send(.noticeRequested(.audioOutput(name: "Speaker", kind: .external, connected: true)))
        machine.send(.systemLocked)
        #expect(machine.notice == nil)
        machine.send(.selectTab(.notes))
        machine.send(.tapped)
        let before = machine.phase
        machine.send(.noticeRequested(.audioOutput(name: "Speaker", kind: .external, connected: true)))
        #expect(machine.phase == before)
        #expect(machine.presentation == .expanded(.notes))
    }

    @Test func bluetoothWaitsForExpandedIslandThenShowsWithoutLosingItsDuration() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.tapped)
        machine.send(.selectTab(.notes))
        let connection = IslandNotice.audioOutput(name: "Berk's headphones", kind: .headphones, connected: true)
        machine.send(.noticeRequested(connection))
        #expect(machine.presentation == .expanded(.notes))
        #expect(machine.notice == nil, "Expanded content stays untouched while the connection waits")

        let effects = machine.send(.escapePressed)
        #expect(machine.phase == .idle)
        #expect(machine.notice == connection)
        #expect(machine.presentation == .notice(connection))
        guard case let .schedule(.noticeDismiss, token, delay)? = effects.first else {
            Issue.record("Deferred connection should receive a fresh full-duration timer"); return
        }
        #expect(delay == connection.duration)
        machine.send(.timerFired(.noticeDismiss, token: token))
        #expect(machine.notice == nil)
    }

    @Test func bluetoothWaitsForPinnedExpandedIslandToClose() {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.tapped)
        machine.send(.togglePin)
        machine.send(.noticeRequested(.audioOutput(name: "Speaker", kind: .external, connected: true)))
        #expect(machine.isExpanded)
        #expect(machine.notice == nil)
        machine.send(.tappedOutside) // a pin intentionally prevents this from closing
        #expect(machine.isExpanded)
        machine.send(.togglePin)
        #expect(!machine.isExpanded)
        #expect(machine.notice == .audioOutput(name: "Speaker", kind: .external, connected: true))
    }

    @Test func expandedIslandQueuesUnlockBeforeBluetoothAndRestoresBothInOrder() throws {
        var machine = IslandMachine(configuration: .init(expandsOnHover: false))
        machine.send(.tapped)
        machine.send(.noticeRequested(.audioOutput(name: "Berk's AirPods", kind: .headphones, connected: true)))
        machine.send(.noticeRequested(.unlocked))
        #expect(machine.presentation == .expanded(.nook))
        let effects = machine.send(.escapePressed)
        #expect(machine.notice == .unlocked)
        guard case let .schedule(.noticeDismiss, unlockToken, unlockDelay)? = effects.first else {
            Issue.record("Unlock should start only once expanded content closes"); return
        }
        #expect(unlockDelay == NoticeTiming.unlock)
        let next = machine.send(.timerFired(.noticeDismiss, token: unlockToken))
        let connection = IslandNotice.audioOutput(name: "Berk's AirPods", kind: .headphones, connected: true)
        #expect(machine.notice == connection)
        guard case let .schedule(.noticeDismiss, connectionToken, _)? = next.first else {
            Issue.record("Queued connection should start after unlock"); return
        }
        machine.send(.timerFired(.noticeDismiss, token: connectionToken))
        #expect(machine.notice == nil)
        #expect(machine.presentation == .idle)
    }

    @Test func feedbackKeepsNotchTopAndHeightAcrossScales() {
        for height in [28.0, 32, 33.5, 38] {
            for scale in [1.0, 2] {
                let metrics = NotchMetrics(notchSize: .init(width: 185, height: height), style: .notch, scale: scale)
                let idle = IslandLayoutEngine.layout(for: .idle, metrics: metrics)
                for notice in [IslandNotice.unlocked, .audioOutput(name: "Long device name", kind: .headphones, connected: true)] {
                    let layout = IslandLayoutEngine.layout(for: .notice(notice), metrics: metrics)
                    #expect(layout.topInset == idle.topInset)
                    #expect(layout.size.height == idle.size.height)
                    #expect(layout.elevation == 0)
                    #expect(layout.size.width <= IslandLayoutEngine.canvasSize(for: metrics).width)
                }
            }
        }
    }
}
