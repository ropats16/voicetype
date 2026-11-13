import XCTest
import CryptoKit
@testable import VoiceType

/// The per-file pins the in-app download uses (`FolderModelPins`): the same
/// tables the download scripts read, and the manifest the app writes from
/// them hashes to the digest its catalog pins — so the app's download and
/// `make whisperkit-model` / `make parakeet-model` produce the same folder.
final class FolderModelPinsTests: XCTestCase {

    /// The app embeds `scripts/<engine>_files.tsv` verbatim; regenerate with
    /// `bash scripts/embed_folder_model_pins.sh` after re-pinning.
    func testTheAppsTablesAreTheScriptsTables() throws {
        for (name, embedded) in [("whisperkit_files.tsv", FolderModelPins.whisperKitTable),
                                 ("parakeet_files.tsv", FolderModelPins.parakeetTable)] {
            let script = try String(contentsOf: FolderModelTable.scripts.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(embedded, script, "\(name) changed: run bash scripts/embed_folder_model_pins.sh")
        }
    }

    func testEveryWhisperKitModelsManifestHashesToItsPin() {
        for model in WhisperKitCatalog.models {
            assertPinned(WhisperKitCatalog.pinnedFiles(for: model.id), manifestSHA256: model.manifestSHA256,
                         bytes: model.bytes, model.id)
        }
    }

    func testEveryParakeetModelsManifestHashesToItsPin() {
        for model in ParakeetCatalog.models {
            assertPinned(ParakeetCatalog.pinnedFiles(for: model.id), manifestSHA256: model.manifestSHA256,
                         bytes: model.bytes, model.id)
        }
    }

    func testAnUnknownModelHasNoFiles() {
        XCTAssertEqual(WhisperKitCatalog.pinnedFiles(for: "my-finetune"), [])
    }

    /// Settings offers a Download button for exactly these: catalog folder
    /// models, fetched into the folder the engine resolves them to.
    func testCatalogFolderModelsDownloadInAppIntoTheirFolder() throws {
        let dir = URL(fileURLWithPath: "/tmp/vt/models")
        let tiny = try XCTUnwrap(WhisperKitEngine().inAppDownload(of: "tiny.en", in: dir))
        XCTAssertEqual(tiny.destination.path, "/tmp/vt/models/whisperkit/tiny.en")
        XCTAssertEqual(tiny.totalBytes, WhisperKitCatalog.model(id: "tiny.en")?.bytes)

        let parakeet = try XCTUnwrap(ParakeetEngine().inAppDownload(of: "parakeet-tdt-0.6b-v3", in: dir))
        XCTAssertEqual(parakeet.destination.path, "/tmp/vt/models/parakeet/parakeet-tdt-0.6b-v3")

        XCTAssertNil(WhisperKitEngine().inAppDownload(of: "my-finetune", in: dir), "nothing pinned to fetch")
        XCTAssertNil(WhisperEngine().inAppDownload(of: "small.en-q5_1", in: dir), "whisper uses make model")
        XCTAssertNil(AppleSpeechEngine().inAppDownload(of: "en", in: dir), "the OS downloads its own")
    }

    /// `shasum -a 256` lines sorted bytewise by path, as `scripts/lib/folder_model.sh` writes.
    func testTheManifestIsShasumLinesSortedByPath() {
        let files = [PinnedFile(source: "r/b", path: "b.json", bytes: 1, sha256: String(repeating: "b", count: 64)),
                     PinnedFile(source: "r/B", path: "B/x.bin", bytes: 1, sha256: String(repeating: "a", count: 64))]
        XCTAssertEqual(FolderModelPins.manifest(files),
                       "\(String(repeating: "a", count: 64))  B/x.bin\n\(String(repeating: "b", count: 64))  b.json\n")
    }

    private func assertPinned(_ files: [PinnedFile], manifestSHA256: String, bytes: Int64, _ id: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(files.isEmpty, "\(id) has files", file: file, line: line)
        let digest = SHA256.hash(data: Data(FolderModelPins.manifest(files).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, manifestSHA256, "\(id) manifest", file: file, line: line)
        XCTAssertEqual(files.map(\.bytes).reduce(0, +), bytes, "\(id) size", file: file, line: line)
    }
}
