import Foundation

@main
struct WAVSpeechChecks {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("✓ \(message)")
    }

    static func wav(seconds: Double, amplitude: Int16, sampleRate: Int = 16_000) -> Data {
        let samples = Int(seconds * Double(sampleRate))
        var data = Data()
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + samples * 2); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(samples * 2)
        for index in 0..<samples {
            let value = index % 2 == 0 ? amplitude : -amplitude
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func main() {
        check(WAVSpeechCheck.evaluate(wav(seconds: 1, amplitude: 4_000)) == .speech, "Audible recording is sent")
        check(WAVSpeechCheck.evaluate(wav(seconds: 0.2, amplitude: 4_000)) == .tooShort, "Recordings under 0.3 s are rejected")
        check(WAVSpeechCheck.evaluate(wav(seconds: 2, amplitude: 40)) == .silent, "Silent recordings are rejected before upload")
        check(WAVSpeechCheck.evaluate(Data("not audio".utf8)) == .unknown, "Unrecognized audio is left to the provider")
    }
}
