//
//  PersistedStore.swift
//  HRT-Recorder
//
//  Created by Mihari on 2025/9/28.
//

import Foundation
import Combine

/// Lightweight JSON persistence for any Codable value.
/// Stores data under Application Support and publishes changes via @Published.
final class PersistedStore<T: Codable>: ObservableObject {
    @Published var value: T
    private var cancellable: AnyCancellable?

    private let url: URL
    private let legacyURL: URL?
    private var needsSave = false

    init(
        filename: String,
        defaultValue: T,
        appGroupIdentifier: String? = nil
    ) {
        let legacyDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appGroupIdentifier.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        } ?? legacyDirectory
        self.url = dir.appendingPathComponent(filename)
        self.legacyURL = dir == legacyDirectory ? nil : legacyDirectory.appendingPathComponent(filename)
        self.value = defaultValue
        createDirIfNeeded(dir)
        load()
        cancellable = $value
            .dropFirst() // ignore the initial assignment from disk/default
            .sink { [weak self] _ in
                self?.needsSave = true
            }
    }

    private func createDirIfNeeded(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func load() {
        let sourceURL: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            sourceURL = url
        } else {
            sourceURL = legacyURL
        }
        guard let sourceURL, let data = try? Data(contentsOf: sourceURL) else { return }
        if let decoded = try? JSONDecoder().decode(T.self, from: data) {
            self.value = decoded
            self.needsSave = false
            // One-time migration to the shared App Group makes plan data
            // available to App Intents hosted outside the foreground process.
            if sourceURL != url {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Synchronous write. Call on scene phase changes (inactive/background) or manually after big edits.
    func saveSync() {
        guard needsSave else { return }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            needsSave = false
        } catch {
            #if DEBUG
            print("PersistedStore save failed:", error)
            #endif
        }
    }
    deinit {
        cancellable?.cancel()
    }
}
