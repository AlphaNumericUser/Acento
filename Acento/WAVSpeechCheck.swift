import Foundation

/// Rejects near-empty or silent 16-bit PCM WAV recordings before upload; Whisper tends to hallucinate text on them.
nonisolated enum WAVSpeechCheck {
    enum Result: Equatable { case speech, tooShort, silent, unknown }

    static let minimumSeconds = 0.3
    static let silencePeak: Int16 = 150

    static func evaluate(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return .unknown }
        func uint32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func uint16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }

        var offset = 12
        var sampleRate = 0, channels = 0, bits = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = uint32(offset + 4)
            let start = offset + 8
            if id == "fmt ", start + 16 <= bytes.count {
                channels = uint16(start + 2)
                sampleRate = uint32(start + 4)
                bits = uint16(start + 14)
            } else if id == "data" {
                guard bits == 16, sampleRate > 0, channels > 0 else { return .unknown }
                let end = min(bytes.count, start + size)
                let samples = (end - start) / 2
                if Double(samples) / Double(sampleRate * channels) < minimumSeconds { return .tooShort }
                var index = start
                while index + 1 < end {
                    let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                    if sample > silencePeak || sample < -silencePeak { return .speech }
                    index += 2
                }
                return .silent
            }
            offset = start + size + (size & 1)
        }
        return .unknown
    }
}
