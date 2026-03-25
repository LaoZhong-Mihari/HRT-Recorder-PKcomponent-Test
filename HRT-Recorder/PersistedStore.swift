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
    private var needsSave = false

    init(filename: String, defaultValue: T) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = dir.appendingPathComponent(filename)
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
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode(T.self, from: data) {
            self.value = decoded
            self.needsSave = false
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
