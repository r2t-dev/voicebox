import AVFoundation
import os

/// One folder per meeting under ~/MiniRecorder.
public struct MeetingFolder: Sendable {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MiniRecorder", isDirectory: true)
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var name: String { url.lastPathComponent }
    public var micURL: URL { url.appendingPathComponent("mic.caf") }
    public var systemURL: URL { url.appendingPathComponent("system.caf") }
    public var micTextURL: URL { url.appendingPathComponent("mic.txt") }
    public var systemTextURL: URL { url.appendingPathComponent("system.txt") }
    public var sessionURL: URL { url.appendingPathComponent("session.json") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.txt") }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    public static func create(startedAt date: Date = Date()) throws -> MeetingFolder {
        let url = root.appendingPathComponent(nameFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return MeetingFolder(url: url)
    }

    /// The start time in a folder name such as 2026-10-22_16-32-34.
    public static func date(fromName name: String) -> Date? {
        nameFormatter.date(from: name)
    }
}

/// One meeting folder, read for the dashboard.
public struct MeetingRecord: Identifiable, Sendable {
    public let folder: MeetingFolder
    public let startedAt: Date
    public let duration: TimeInterval?
    public let session: SessionInfo?
    /// The text of transcript.txt, or nil if the meeting has no transcript yet.
    public let transcript: String?
    public let lines: [TranscriptLine]
    public let hasAudio: Bool

    public var id: String { folder.name }

    public static func load(_ folder: MeetingFolder) -> MeetingRecord {
        let fileManager = FileManager.default
        let session = try? SessionInfo.load(from: folder.sessionURL)
        let transcript = try? String(contentsOf: folder.transcriptURL, encoding: .utf8)
        let created = try? folder.url.resourceValues(forKeys: [.creationDateKey]).creationDate
        // The end of the later track on the session clock, the same length that playback shows.
        let trackEnds = [(folder.micURL, session?.micOffset ?? 0), (folder.systemURL, session?.systemOffset ?? 0)]
            .compactMap { url, offset in audioDuration(url).map { $0 + offset } }
        return MeetingRecord(
            folder: folder,
            startedAt: session?.startedAt ?? MeetingFolder.date(fromName: folder.name) ?? created ?? .distantPast,
            duration: trackEnds.max() ?? session.map { $0.stoppedAt.timeIntervalSince($0.startedAt) },
            session: session,
            transcript: transcript,
            lines: transcript.map(TranscriptMerger.parse) ?? [],
            hasAudio: fileManager.fileExists(atPath: folder.micURL.path)
                || fileManager.fileExists(atPath: folder.systemURL.path))
    }

    /// Every folder under `root` that holds a recording or a transcript, newest first.
    public static func loadAll(in root: URL = MeetingFolder.root) -> [MeetingRecord] {
        let fileManager = FileManager.default
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return
            urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { MeetingFolder(url: $0) }
            .filter {
                [$0.micURL, $0.systemURL, $0.transcriptURL].contains { fileManager.fileExists(atPath: $0.path) }
            }
            .map(load)
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func audioDuration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

/// What the recorders measured, saved as session.json next to the audio files.
public struct SessionInfo: Codable, Sendable {
    public var startedAt: Date
    public var stoppedAt: Date
    /// Seconds from the earliest first sample of the two tracks to the first sample of this track.
    public var micOffset: Double
    public var systemOffset: Double
    public var micPeak: Float
    public var systemPeak: Float
    public var micFrames: Int64
    public var systemFrames: Int64

    public init(startedAt: Date, stoppedAt: Date, mic: TrackStats.Snapshot, system: TrackStats.Snapshot) {
        let base = [mic.firstHostTime, system.firstHostTime].filter { $0 > 0 }.min() ?? 0
        func offset(_ hostTime: UInt64) -> Double {
            hostTime > base ? hostTimeToSeconds(hostTime - base) : 0
        }
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        micOffset = offset(mic.firstHostTime)
        systemOffset = offset(system.firstHostTime)
        micPeak = mic.peak
        systemPeak = system.peak
        micFrames = mic.frames
        systemFrames = system.frames
    }

    public static func load(from url: URL) throws -> SessionInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionInfo.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Writes to the unified log and to ~/MiniRecorder/minirecorder.log.
public enum Log {
    private static let logger = Logger(subsystem: "local.minirecorder", category: "app")
    private static let queue = DispatchQueue(label: "local.minirecorder.log")

    public static var fileURL: URL { MeetingFolder.root.appendingPathComponent("minirecorder.log") }

    public static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        queue.async {
            try? FileManager.default.createDirectory(at: MeetingFolder.root, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: fileURL)
            }
        }
    }
}
