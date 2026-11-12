import Foundation
import CoreMedia

nonisolated enum RecordingStorage {
    static let dataFolderName = "Acento"

    static func folder(_ name: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // Resolved once: rows look up recordings on every render.
    private static let recordingsFolder = try? folder("Recordings")

    static func url(for filename: String) -> URL? {
        guard filename.hasSuffix(".wav"), UUID(uuidString: String(filename.dropLast(4))) != nil,
              let folder = recordingsFolder else { return nil }
        return folder.appendingPathComponent(filename)
    }

    static func delete(_ filename: String?) {
        guard let filename, let url = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static let retentionDays = 15

    static func modificationDate(_ filename: String) -> Date? {
        guard let url = url(for: filename) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Removes recordings not referenced by any dictation and last modified before `cutoff`.
    /// Recent files are kept because an in-progress dictation may not be in the history yet.
    static func deleteUnreferenced(keeping referenced: Set<String>, olderThan cutoff: Date) {
        guard let folder = recordingsFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "wav" && !referenced.contains(file.lastPathComponent) {
            guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date < cutoff else { continue }
            delete(file.lastPathComponent)
        }
    }

    /// The saved recording for a dictation, only if the file still exists on disk.
    static func existingURL(for filename: String?) -> URL? {
        guard let filename, let url = url(for: filename),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

nonisolated final class WaveWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private var byteCount: UInt32 = 0
    private var sampleRate: UInt32 = 0
    private var channelCount: UInt16 = 0
    private var failure: Error?
    private var finished = false

    init() throws {
        url = try RecordingStorage.folder("Recordings").appendingPathComponent("\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 44)) else {
            throw SpeechFailure("Could not create the recording.")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ buffer: CMSampleBuffer) {
        guard !finished, failure == nil, let dataBuffer = CMSampleBufferGetDataBuffer(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0, length <= Int(UInt32.max - byteCount), format.pointee.mBitsPerChannel == 16 else { return }
        if sampleRate == 0 {
            sampleRate = UInt32(format.pointee.mSampleRate)
            channelCount = UInt16(format.pointee.mChannelsPerFrame)
        }
        var bytes = Data(count: length)
        let result = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard result == noErr else { return }
        do {
            try handle.write(contentsOf: bytes)
            byteCount += UInt32(length)
        } catch { failure = error }
    }

    func finish() throws -> URL {
        finished = true
        defer { try? handle.close() }
        if let failure { throw failure }
        guard byteCount > 0, byteCount <= UInt32.max - 36, sampleRate > 0, channelCount > 0 else {
            throw SpeechFailure("No audio was recorded. Check the microphone selection.")
        }
        var header = Data("RIFF".utf8)
        header.appendLE(36 + byteCount)
        header.append(Data("WAVEfmt ".utf8))
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))
        header.appendLE(channelCount)
        header.appendLE(sampleRate)
        header.appendLE(sampleRate * UInt32(channelCount) * 2)
        header.appendLE(channelCount * 2)
        header.appendLE(UInt16(16))
        header.append(Data("data".utf8))
        header.appendLE(byteCount)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        return url
    }
}

private extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

extension AppModel {
    /// Keeps audio for the last `RecordingStorage.retentionDays` days. Older dictations keep only their
    /// transcript; failed transcriptions keep their audio so they can still be retried.
    func pruneRecordings(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(RecordingStorage.retentionDays) * 86_400)
        removeAudio { entry in
            guard !entry.isFailed, let file = entry.audioFile,
                  let date = entry.createdAt ?? RecordingStorage.modificationDate(file) else { return false }
            return date < cutoff
        }
        RecordingStorage.deleteUnreferenced(keeping: Set(history.compactMap(\.audioFile)), olderThan: cutoff)
    }
}
