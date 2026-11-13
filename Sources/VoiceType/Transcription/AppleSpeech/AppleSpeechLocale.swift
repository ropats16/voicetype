import Foundation

/// Maps the app's language setting (`ModelSpec.language`: an ISO code or
/// `ModelSpec.autoDetect`) to a locale `SpeechTranscriber` supports.
enum AppleSpeechLocale {
    /// The supported locale for `language`, or nil if the transcriber can't do
    /// that language.
    ///
    /// - A code with a region ("en-GB") keeps it when supported.
    /// - Otherwise the language's main region (likely subtags: en → US,
    ///   pt → BR), else its first supported region alphabetically.
    /// - `ModelSpec.autoDetect`: the transcriber can't detect the language, so
    ///   this means the Mac's own — `systemLocale`, then `preferredLanguages`,
    ///   by the same rules — falling back to en-US, the broadest model.
    ///
    /// Deterministic, unlike `SpeechTranscriber.supportedLocale(equivalentTo:)`,
    /// which was seen to map "en" to en_US on one call and en_IN on the next.
    static func resolve(language: String, supported: [Locale],
                        systemLocale: Locale = .current,
                        preferredLanguages: [String] = Locale.preferredLanguages) -> Locale? {
        let isAuto = language == ModelSpec.autoDetect
        let wanted = isAuto ? [systemLocale] + preferredLanguages.map(Locale.init(identifier:))
                            : [Locale(identifier: language)]
        let byID = supported.sorted { $0.identifier < $1.identifier }
        func match(_ language: String?, _ region: String?) -> Locale? {
            guard let language, let region else { return nil }
            return byID.first { Self.language(of: $0) == language && Self.region(of: $0) == region }
        }

        for locale in wanted {
            if let exact = match(Self.language(of: locale), Self.region(of: locale)) { return exact }
        }
        for locale in wanted {
            guard let lang = Self.language(of: locale) else { continue }
            if let main = match(lang, Self.mainRegion(of: lang)) { return main }
            if let any = byID.first(where: { Self.language(of: $0) == lang }) { return any }
        }
        return isAuto ? match("en", "US") : nil
    }

    private static func language(of locale: Locale) -> String? { locale.language.languageCode?.identifier }
    private static func region(of locale: Locale) -> String? { locale.region?.identifier }

    /// The region a bare language code most likely means (CLDR likely subtags).
    private static func mainRegion(of language: String) -> String? {
        Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier).region?.identifier
    }
}
