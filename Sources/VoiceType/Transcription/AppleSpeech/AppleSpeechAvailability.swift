import Foundation
import Speech

/// Whether Apple's on-device SpeechAnalyzer engine (#14) can be offered on this
/// Mac. The engine registry hides it where this is false; the binary itself
/// still runs on macOS 14 (Speech links there, the new API is just absent).
enum AppleSpeechAvailability {
    /// SpeechAnalyzer / SpeechTranscriber shipped in macOS 26.
    static let minimumOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    static func isOSSupported(_ version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion, version.patchVersion)
            >= (minimumOS.majorVersion, minimumOS.minorVersion, minimumOS.patchVersion)
    }

    /// macOS 26 or later, and hardware that runs `SpeechTranscriber` (some
    /// devices only get the older `DictationTranscriber`). `transcriberAvailable`
    /// is only asked on a supported OS.
    static func isAvailable(os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                            transcriberAvailable: () -> Bool = transcriberAvailableOnThisMac) -> Bool {
        isOSSupported(os) && transcriberAvailable()
    }

    static func transcriberAvailableOnThisMac() -> Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }
}
