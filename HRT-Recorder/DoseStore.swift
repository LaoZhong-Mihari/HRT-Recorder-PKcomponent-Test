import CryptoKit
import Combine
import Foundation

/// The canonical event store shared by the UI and App Intents.
///
/// Earlier versions let `PersistedStore` and `DoseRecordingService` both write
/// `dose_events.json`.  A Siri write could consequently be overwritten by an
/// older in-memory UI snapshot.  This document keeps the event list, a
/// monotonic revision, and a small idempotency journal in one coordinated
/// transaction.
struct DoseStoreSnapshot: Equatable, Sendable {
    let revision: UInt64
    let events: [DoseEvent]
    let modifiedAt: TimeInterval
}

enum DoseStoreOperation: Sendable {
    case upsert(DoseEvent)
    case delete(UUID)
}

struct DoseStoreMutation: Sendable {
    let id: UUID
    let operation: DoseStoreOperation
    let source: String
    /// A SHA-256 digest of a fully-resolved Siri draft. It is deliberately not
    /// the spoken text, so the on-disk journal does not retain a transcript.
    let fingerprint: String?

    init(
        id: UUID = UUID(),
        operation: DoseStoreOperation,
        source: String,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.source = source
        self.fingerprint = fingerprint
    }
}

struct DoseStoreApplyResult: Sendable {
    let snapshot: DoseStoreSnapshot
    let didApply: Bool
    let resolvedEvent: DoseEvent?
}

enum DoseStoreError: LocalizedError {
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            return String(localized: "I could not read your saved dosing data.")
        case .writeFailed:
            return String(localized: "I could not save the dose.")
        }
    }
}

private struct DoseStoreReceipt: Codable, Sendable {
    let mutationID: UUID
    let eventID: UUID?
    let fingerprint: String?
    let appliedAt: Date
}

private struct DoseStoreDocument: Codable, Sendable {
    var schemaVersion: Int
    var revision: UInt64
    var modifiedAt: TimeInterval
    var events: [DoseEvent]
    var receipts: [DoseStoreReceipt]

    static let empty = DoseStoreDocument(
        schemaVersion: 1,
        revision: 0,
        modifiedAt: 0,
        events: [],
        receipts: []
    )
}

/// A small file-backed event repository. `NSFileCoordinator` makes the
/// read-modify-write sequence safe when an App Intent is hosted outside the
/// foreground app process.
enum DoseStore {
    static let didChangeNotification = Notification.Name("HRTRecorder.DoseStore.didChange")

    private static let eventsFileName = "dose_events.json"
    private static let lock = NSLock()
    private static let receiptLimit = 256
    private static let fingerprintRetryWindow: TimeInterval = 60

    static func load() throws -> DoseStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let url = try fileURL()
        var document = DoseStoreDocument.empty
        var readError: Error?
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                document = try readDocument(at: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        return snapshot(from: document)
    }

    @discardableResult
    static func apply(_ mutation: DoseStoreMutation) throws -> DoseStoreApplyResult {
        lock.lock()
        defer { lock.unlock() }

        let url = try fileURL()
        var result: DoseStoreApplyResult?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                var document = try readDocument(at: coordinatedURL)
                let now = Date()

                if let existing = document.receipts.first(where: { $0.mutationID == mutation.id }) {
                    result = DoseStoreApplyResult(
                        snapshot: snapshot(from: document),
                        didApply: false,
                        resolvedEvent: existing.eventID.flatMap { id in document.events.first(where: { $0.id == id }) }
                    )
                    return
                }

                if let fingerprint = mutation.fingerprint,
                   let existing = document.receipts.last(where: {
                       $0.fingerprint == fingerprint && now.timeIntervalSince($0.appliedAt) <= fingerprintRetryWindow
                   }) {
                    document.receipts.append(
                        DoseStoreReceipt(
                            mutationID: mutation.id,
                            eventID: existing.eventID,
                            fingerprint: fingerprint,
                            appliedAt: now
                        )
                    )
                    document.receipts = trimmedReceipts(document.receipts, now: now)
                    try writeDocument(document, to: coordinatedURL)
                    result = DoseStoreApplyResult(
                        snapshot: snapshot(from: document),
                        didApply: false,
                        resolvedEvent: existing.eventID.flatMap { id in document.events.first(where: { $0.id == id }) }
                    )
                    return
                }

                let eventID: UUID?
                switch mutation.operation {
                case .upsert(let event):
                    if let index = document.events.firstIndex(where: { $0.id == event.id }) {
                        document.events[index] = event
                    } else {
                        document.events.append(event)
                    }
                    document.events.sort { $0.timeH < $1.timeH }
                    eventID = event.id

                case .delete(let id):
                    document.events.removeAll { $0.id == id }
                    eventID = id
                }

                document.revision &+= 1
                document.modifiedAt = now.timeIntervalSince1970
                document.receipts.append(
                    DoseStoreReceipt(
                        mutationID: mutation.id,
                        eventID: eventID,
                        fingerprint: mutation.fingerprint,
                        appliedAt: now
                    )
                )
                document.receipts = trimmedReceipts(document.receipts, now: now)
                try writeDocument(document, to: coordinatedURL)
                result = DoseStoreApplyResult(
                    snapshot: snapshot(from: document),
                    didApply: true,
                    resolvedEvent: eventID.flatMap { id in document.events.first(where: { $0.id == id }) }
                )
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard let result else { throw DoseStoreError.writeFailed }

        notifyDidChange()
        return result
    }

    /// Applies edits made against a UI baseline without replacing events that
    /// arrived from Siri or the Watch after that baseline was read.
    @discardableResult
    static func mergePresentationChanges(
        baseline: [DoseEvent],
        proposed: [DoseEvent]
    ) throws -> DoseStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let url = try fileURL()
        var snapshotResult: DoseStoreSnapshot?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                var document = try readDocument(at: coordinatedURL)
                let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
                let proposedByID = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
                var changed = false

                for (id, event) in proposedByID where baselineByID[id] != event {
                    if let index = document.events.firstIndex(where: { $0.id == id }) {
                        document.events[index] = event
                    } else {
                        document.events.append(event)
                    }
                    changed = true
                }

                for id in baselineByID.keys where proposedByID[id] == nil {
                    let originalCount = document.events.count
                    document.events.removeAll { $0.id == id }
                    changed = changed || document.events.count != originalCount
                }

                if changed {
                    document.events.sort { $0.timeH < $1.timeH }
                    document.revision &+= 1
                    document.modifiedAt = Date().timeIntervalSince1970
                    document.receipts.append(
                        DoseStoreReceipt(
                            mutationID: UUID(),
                            eventID: nil,
                            fingerprint: nil,
                            appliedAt: Date()
                        )
                    )
                    document.receipts = trimmedReceipts(document.receipts, now: Date())
                    try writeDocument(document, to: coordinatedURL)
                }
                snapshotResult = snapshot(from: document)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard let snapshotResult else { throw DoseStoreError.writeFailed }

        if snapshotResult.events != baseline {
            notifyDidChange()
        }
        return snapshotResult
    }

    nonisolated static func fingerprint(for canonicalValues: [String]) -> String {
        let data = canonicalValues.joined(separator: "\u{1F}").data(using: .utf8) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshot(from document: DoseStoreDocument) -> DoseStoreSnapshot {
        DoseStoreSnapshot(
            revision: document.revision,
            events: document.events.sorted { $0.timeH < $1.timeH },
            modifiedAt: document.modifiedAt
        )
    }

    private static func readDocument(at url: URL) throws -> DoseStoreDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The original app stored raw events in Application Support. Move
            // reads to the App Group without losing that history; the next
            // canonical mutation writes the upgraded document into the shared
            // container used by the app and its extensions.
            let legacyURL = legacyApplicationSupportURL()
            guard url.path != legacyURL.path,
                  FileManager.default.fileExists(atPath: legacyURL.path) else {
                return .empty
            }
            return try readDocumentContents(at: legacyURL)
        }

        return try readDocumentContents(at: url)
    }

    private static func readDocumentContents(at url: URL) throws -> DoseStoreDocument {
        do {
            let data = try Data(contentsOf: url)
            if let document = try? JSONDecoder().decode(DoseStoreDocument.self, from: data) {
                return document
            }
            // Upgrade the historic raw JSON array without dropping the user's
            // existing dose history.
            if let legacyEvents = try? JSONDecoder().decode([DoseEvent].self, from: data) {
                return DoseStoreDocument(
                    schemaVersion: 1,
                    revision: 0,
                    modifiedAt: 0,
                    events: legacyEvents.sorted { $0.timeH < $1.timeH },
                    receipts: []
                )
            }
            throw DoseStoreError.readFailed
        } catch let error as DoseStoreError {
            throw error
        } catch {
            throw DoseStoreError.readFailed
        }
    }

    private static func writeDocument(_ document: DoseStoreDocument, to url: URL) throws {
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            throw DoseStoreError.writeFailed
        }
    }

    private static func trimmedReceipts(_ receipts: [DoseStoreReceipt], now: Date) -> [DoseStoreReceipt] {
        let recent = receipts.filter { now.timeIntervalSince($0.appliedAt) <= 24 * 60 * 60 }
        return Array(recent.suffix(receiptLimit))
    }

    private static func fileURL() throws -> URL {
        let directory = sharedDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(eventsFileName)
        } catch {
            throw DoseStoreError.writeFailed
        }
    }

    private static func sharedDirectory() -> URL {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedStore.appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func legacyApplicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(eventsFileName)
    }

    private static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: "mihari.HRT-Recorder-beta.dose-store-changed" as CFString),
            nil,
            nil,
            true
        )
    }
}

@MainActor
final class DoseStoreController: NSObject, ObservableObject {
    @Published private(set) var snapshot: DoseStoreSnapshot
    private var darwinObserverInstalled = false

    var events: [DoseEvent] { snapshot.events }

    override init() {
        snapshot = (try? DoseStore.load()) ?? DoseStoreSnapshot(revision: 0, events: [], modifiedAt: 0)
        super.init()
    }

    func commitPresentationChanges(proposed: [DoseEvent]) -> DoseStoreSnapshot {
        do {
            let updated = try DoseStore.mergePresentationChanges(
                baseline: snapshot.events,
                proposed: proposed
            )
            snapshot = updated
            return updated
        } catch {
            return snapshot
        }
    }

    func reload() {
        guard let updated = try? DoseStore.load(), updated.revision >= snapshot.revision else { return }
        snapshot = updated
    }

    func startObserving() {
        guard !darwinObserverInstalled else { return }
        darwinObserverInstalled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange(_:)),
            name: DoseStore.didChangeNotification,
            object: nil
        )

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<DoseStoreController>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in controller.reload() }
            },
            "mihari.HRT-Recorder-beta.dose-store-changed" as CFString,
            nil,
            .deliverImmediately
        )
    }

    @objc private func handleStoreChange(_ notification: Notification) {
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if darwinObserverInstalled {
            let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                CFNotificationName(rawValue: "mihari.HRT-Recorder-beta.dose-store-changed" as CFString),
                nil
            )
        }
    }
}
