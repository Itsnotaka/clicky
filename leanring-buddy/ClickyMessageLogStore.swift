//
//  ClickyMessageLogStore.swift
//  leanring-buddy
//
//  Structured local JSONL logging for agent, computer-use, and dashboard events.
//

import Foundation

struct ClickyMessageLogEntry: Codable, Equatable {
    let timestamp: String
    let lane: String
    let direction: String
    let event: String
    let fields: [String: String]
}

struct ClickyMessageLogDisplayEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: String
    let lane: String
    let direction: String
    let event: String
    let fieldsSummary: String
    let sourceFileName: String
    let sourceLineNumber: Int
}

nonisolated final class ClickyMessageLogStore: @unchecked Sendable {
    static let shared = ClickyMessageLogStore()

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let writeQueue = DispatchQueue(label: "com.clicky.message-log-writes", qos: .utility)

    let logDirectory: URL

    var currentLogFile: URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return logDirectory.appendingPathComponent("messages-\(formatter.string(from: Date())).jsonl", isDirectory: false)
    }

    init(fileManager: FileManager = .default, logDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.logDirectory = logDirectory ?? Self.defaultLogDirectory(fileManager: fileManager)
        encoder.outputFormatting = [.sortedKeys]
    }

    func append(lane: String, direction: String, event: String, fields: [String: String] = [:]) {
        let sanitizedFields = Self.sanitizedFields(fields)
        let entry = ClickyMessageLogEntry(
            timestamp: Self.timestampString(for: Date()),
            lane: lane,
            direction: direction,
            event: event,
            fields: sanitizedFields
        )

        writeQueue.async {
            do {
                try self.fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
                var data = try self.encoder.encode(entry)
                data.append(0x0A)
                try self.append(data, to: self.currentLogFile)
            } catch {
                print("Clicky message log write failed: \(error.localizedDescription)")
            }
        }
    }

    func availableLogFiles() -> [URL] {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            return try files
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("messages-") }
                .sorted { firstFile, secondFile in
                    let firstDate = try firstFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                    let secondDate = try secondFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                    return firstDate > secondDate
                }
        } catch {
            print("Clicky message log listing failed: \(error.localizedDescription)")
            return []
        }
    }

    func recentDisplayEntries(limit: Int = 80) -> [ClickyMessageLogDisplayEntry] {
        var entries: [ClickyMessageLogDisplayEntry] = []

        for fileURL in availableLogFiles().prefix(5) {
            entries.append(contentsOf: displayEntries(from: fileURL))
        }

        return Array(entries.suffix(limit).reversed())
    }

    private func displayEntries(from fileURL: URL) -> [ClickyMessageLogDisplayEntry] {
        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            return lines.enumerated().compactMap { lineIndex, line in
                guard let data = line.data(using: .utf8) else { return nil }
                do {
                    let entry = try decoder.decode(ClickyMessageLogEntry.self, from: data)
                    return Self.displayEntry(
                        from: entry,
                        sourceFileName: fileURL.lastPathComponent,
                        sourceLineNumber: lineIndex + 1
                    )
                } catch {
                    return nil
                }
            }
        } catch {
            print("Clicky message log read failed: \(error.localizedDescription)")
            return []
        }
    }

    private func append(_ data: Data, to fileURL: URL) throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    private static func defaultLogDirectory(fileManager: FileManager) -> URL {
        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private static func displayEntry(
        from entry: ClickyMessageLogEntry,
        sourceFileName: String,
        sourceLineNumber: Int
    ) -> ClickyMessageLogDisplayEntry {
        ClickyMessageLogDisplayEntry(
            id: UUID(),
            timestamp: entry.timestamp,
            lane: entry.lane,
            direction: entry.direction,
            event: entry.event,
            fieldsSummary: fieldsSummary(entry.fields),
            sourceFileName: sourceFileName,
            sourceLineNumber: sourceLineNumber
        )
    }

    private static func sanitizedFields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { partialResult, field in
            partialResult[field.key] = isSensitiveKey(field.key) ? "[redacted]" : field.value
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalizedKey = key.lowercased()
        return normalizedKey.contains("token")
            || normalizedKey.contains("secret")
            || normalizedKey.contains("password")
            || normalizedKey.contains("apikey")
            || normalizedKey.contains("api_key")
            || normalizedKey.contains("authorization")
            || normalizedKey == "key"
    }

    private static func fieldsSummary(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }

        let summary = fields
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { key, value in
                "\(key)=\(shortValueDescription(value))"
            }
            .joined(separator: " · ")

        guard summary.count > 260 else { return summary }
        return String(summary.prefix(257)) + "..."
    }

    private static func shortValueDescription(_ value: String) -> String {
        let singleLineValue = value.replacingOccurrences(of: "\n", with: " ")
        guard singleLineValue.count > 80 else { return singleLineValue }
        return String(singleLineValue.prefix(77)) + "..."
    }

    private static func timestampString(for date: Date) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return isoFormatter.string(from: date)
    }
}
