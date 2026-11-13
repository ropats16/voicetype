import Foundation
import Speech

/// Where the OS-managed speech model for one locale stands. Apple's engine has
/// no model file: macOS downloads, stores and updates the model, and this is
/// what the app shows in place of a file's presence.
///
/// How it maps onto `TranscriptionStatus` (`AppleSpeechEngine.isPresent`):
/// - `.installed` → present; `load()` goes `.loading` → `.ready` as for a file.
/// - `.notInstalled` → `.missing`, with the engine's "Open Settings › Model"
///   hint; Settings' Download button calls `AppleSpeechAssets.install`.
/// - `.downloading` → `.missing` too, Settings showing the progress; when the
///   install finishes (from Settings or elsewhere) the engine loads it.
///   (Not `.loading`: that means "a job submitted now waits for it", and a
///   download can take minutes or fail.)
/// - `.unsupported` → present, so the load runs and fails (`.failed`) with
///   `AppleSpeechError.unsupportedLanguage`; Settings shows "Not available".
enum AppleSpeechAssetState: Equatable {
    /// This Mac can't transcribe that language with SpeechTranscriber.
    case unsupported
    /// Downloadable; `AppleSpeechAssets.install` fetches it.
    case notInstalled
    /// Being downloaded. `progress` (0…1) is known only for an install this
    /// app started; the OS doesn't report it for others.
    case downloading(progress: Double?)
    case installed

    /// `AssetInventory.Status`, mirrored so this maps (and tests) on any macOS.
    enum Inventory: Equatable {
        case unsupported, supported, downloading, installed
    }

    /// `inventory` is the OS's status for this app; `installedOnMac` whether the
    /// locale is in `SpeechTranscriber.installedLocales`; `installProgress` the
    /// progress of an install this app has under way, if any.
    ///
    /// The inventory reports `supported` for a model already on the Mac (another
    /// app downloaded it) until this app reserves the locale, yet it transcribes
    /// fine; so that counts as installed, and the adapter reserves it.
    init(inventory: Inventory, installedOnMac: Bool, installProgress: Double?) {
        switch inventory {
        case .unsupported: self = .unsupported
        case .installed: self = .installed
        case .supported where installedOnMac: self = .installed
        case .supported, .downloading:
            self = installProgress != nil || inventory == .downloading
                ? .downloading(progress: installProgress) : .notInstalled
        }
    }

    /// Only an installed model transcribes; the adapter never downloads one.
    var canTranscribe: Bool { self == .installed }
}

/// The OS-managed speech models behind the Apple SpeechAnalyzer engine: their
/// state per language, and an explicit install (download) the user starts,
/// e.g. from Settings. Transcription never downloads anything.
@available(macOS 26, *)
enum AppleSpeechAssets {
    /// The transcriber configuration the adapter runs: final results only
    /// (no volatile partials), with per-word audio time ranges. The model's
    /// assets are the same for every configuration of a locale.
    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    /// The locale the engine uses for `language` (see `AppleSpeechLocale`), or
    /// nil if this Mac can't transcribe it.
    static func locale(for language: String) async -> Locale? {
        guard AppleSpeechAvailability.isAvailable() else { return nil }
        return AppleSpeechLocale.resolve(language: language, supported: await SpeechTranscriber.supportedLocales)
    }

    static func state(for language: String) async -> AppleSpeechAssetState {
        guard let locale = await locale(for: language) else { return .unsupported }
        return await state(for: locale)
    }

    static func state(for locale: Locale) async -> AppleSpeechAssetState {
        let inventory = await AssetInventory.status(forModules: [transcriber(for: locale)])
        let onMac = await SpeechTranscriber.installedLocales.contains { same($0, locale) }
        return AppleSpeechAssetState(inventory: .init(inventory), installedOnMac: onMac,
                                     installProgress: installs.progress(of: locale))
    }

    /// Downloads and installs the model for `language` (and reserves its locale
    /// for this app), reporting progress 0…1 as it goes. Returns at once if it
    /// is already installed. Throws `AppleSpeechError.unsupportedLanguage` if
    /// the language can't be transcribed here.
    static func install(language: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let locale = await locale(for: language) else {
            throw AppleSpeechError.unsupportedLanguage(language)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(for: locale)])
        else { return progress(1) }
        installs.begin(locale, request.progress)
        defer { installs.end(locale) }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Reserves `locale` for this app if it isn't already, so the OS keeps its
    /// model (an app may hold `AssetInventory.maximumReservedLocales`).
    /// Best-effort: a model on the Mac transcribes unreserved too.
    static func reserve(_ locale: Locale) async {
        guard await !AssetInventory.reservedLocales.contains(where: { same($0, locale) }) else { return }
        do { try await AssetInventory.reserve(locale: locale) } catch {
            Log.info("Couldn't reserve the \(locale.identifier) speech model: \(error.localizedDescription)")
        }
    }

    static func same(_ a: Locale, _ b: Locale) -> Bool {
        a.language.languageCode == b.language.languageCode && a.region == b.region
    }

    /// Installs this app has under way, by locale.
    private static let installs = InstallTracker()
}

@available(macOS 26, *)
private extension AppleSpeechAssetState.Inventory {
    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported: self = .unsupported
        case .supported: self = .supported
        case .downloading: self = .downloading
        case .installed: self = .installed
        @unknown default: self = .unsupported
        }
    }
}

private final class InstallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Progress] = [:]

    func begin(_ locale: Locale, _ progress: Progress) { lock.withLock { running[locale.identifier] = progress } }
    func end(_ locale: Locale) { lock.withLock { running[locale.identifier] = nil } }
    func progress(of locale: Locale) -> Double? { lock.withLock { running[locale.identifier]?.fractionCompleted } }
}

/// The OS-managed speech models as Settings sees them (Apple Speech): the
/// state for a language, and the download the user starts. A port, so the
/// view model is testable without the OS.
protocol SpeechModelAssets: Sendable {
    func state(language: String) async -> AppleSpeechAssetState
    func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// `AppleSpeechAssets`, or unsupported below macOS 26.
struct LiveSpeechModelAssets: SpeechModelAssets {
    func state(language: String) async -> AppleSpeechAssetState {
        guard #available(macOS 26, *) else { return .unsupported }
        return await AppleSpeechAssets.state(for: language)
    }

    func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unavailable }
        try await AppleSpeechAssets.install(language: language, progress: progress)
    }
}
