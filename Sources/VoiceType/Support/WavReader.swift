import Foundation

/// Minimal WAV loader for the `--selftest` diagnostic: reads 16-bit PCM,
/// downmixes to mono, and returns Float32 samples in [-1, 1]. Whisper expects
/// 16 kHz; this loader does not resample, so feed it 16 kHz audio.
enum WavReader {
    enum WavError: LocalizedError {
        case notAWav, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .notAWav: return "Not a RIFF/WAVE file."
            case .unsupported(let s): return "Unsupported WAV: \(s)"
            }
        }
    }

    struct Audio { let samples: [Float]; let sampleRate: Int }

    static func load(path: String) throws -> Audio {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o+1]) << 8 | UInt32(data[o+2]) << 16 | UInt32(data[o+3]) << 24
        }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o+1]) << 8 }

        guard data.count > 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,  // "RIFF"
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 // "WAVE"
        else { throw WavError.notAWav }

        var channels = 1, sampleRate = 16000, bits = 16
        var dataOffset = -1, dataSize = 0
        var o = 12
        while o + 8 <= data.count {
            let id = String(bytes: data[o..<o+4], encoding: .ascii) ?? ""
            let size = Int(u32(o + 4))
            let body = o + 8
            if id == "fmt " {
                channels = Int(u16(body + 2))
                sampleRate = Int(u32(body + 4))
                bits = Int(u16(body + 14))
            } else if id == "data" {
                dataOffset = body
                dataSize = min(size, data.count - body)
            }
            o = body + size + (size & 1)   // chunks are word-aligned
        }

        guard bits == 16 else { throw WavError.unsupported("\(bits)-bit (need 16-bit PCM)") }
        guard dataOffset >= 0 else { throw WavError.unsupported("no data chunk") }

        let frameCount = dataSize / (2 * channels)
        var samples = [Float](repeating: 0, count: frameCount)
        var p = dataOffset
        for i in 0..<frameCount {
            var acc: Int32 = 0
            for _ in 0..<channels {
                let raw = Int16(bitPattern: u16(p))
                acc += Int32(raw)
                p += 2
            }
            samples[i] = Float(acc) / Float(channels) / 32768.0
        }
        return Audio(samples: samples, sampleRate: sampleRate)
    }
}
