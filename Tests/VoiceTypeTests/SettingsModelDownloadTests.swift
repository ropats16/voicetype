import XCTest
import Combine
import ServiceManagement
@testable import VoiceType

/// Settings' Download button for folder-model engines (WhisperKit,
/// Parakeet): offered for catalog models that aren't installed, shows
/// progress, can be cancelled, says why it failed, and when the selected
/// model lands re-applies the model settings so the engine loads it. The
/// engine and the downloader are faked; the models folder is a temp one, and
/// nothing touches the network.
@MainActor
final class SettingsModelDownloadTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    /// Which fake models are installed; the fake downloader adds to it.
    private final class Installed: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String>
        init(_ ids: Set<String>) { self.ids = ids }
        func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
        func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    }

    /// A folder-model engine whose models "fast" and "big" download in-app.
    private struct DownloadableEngine: EngineDescriptor {
        let kind = EngineKind.whisperKit
        let installed: Installed
        let models = [EngineModelOption(id: "fast", label: "Fast"), EngineModelOption(id: "big", label: "Big")]
        let acknowledgement = "Fake engine, for tests."

        func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
            let id: String
            switch choice {
            case .automatic: id = "fast"
            case .named(let named): id = named
            }
            return ModelSpec(path: context.modelsDir.appendingPathComponent("fake/\(id)").path, sha256: nil,
                             language: context.language, engine: kind)
        }

        func isPresent(_ spec: ModelSpec) -> Bool { installed.contains(URL(fileURLWithPath: spec.path).lastPathComponent) }

        func downloadHint(for spec: ModelSpec) -> ModelDownloadHint? {
            .command("make fake-model FAKE=\(URL(fileURLWithPath: spec.path).lastPathComponent)")
        }

        func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload? {
            ModelDownload(modelID: id, files: [PinnedFile(source: "r/\(id)", path: "w.bin", bytes: 10_000, sha256: "")],
                          destination: modelsDir.appendingPathComponent("fake/\(id)"))
        }

        func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
            { _ in EchoAdapter(name: "fake") }
        }
    }

    /// Reports `steps`, then (if `holds`) waits until released or cancelled,
    /// then fails with `error` or installs the model.
    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let installed: Installed
        var steps: [Int64] = []
        var holds = false
        var error: Error?
        private let lock = NSLock()
        private var _started: [String] = []
        private var released = false
        private var release: CheckedContinuation<Void, Never>?

        init(installed: Installed) { self.installed = installed }

        var started: [String] { lock.withLock { _started } }

        func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws {
            lock.withLock { _started.append(download.modelID) }
            steps.forEach(progress)
            if holds {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let now = lock.withLock { () -> Bool in
                            if released { return true }
                            release = continuation
                            return false
                        }
                        if now { continuation.resume() }
                    }
                } onCancel: { [weak self] in
                    self?.finishHolding()
                }
                try Task.checkCancellation()
            }
            if let error { throw error }
            installed.insert(download.modelID)
        }

        func finishHolding() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { release = nil }
                return release
            }
            continuation?.resume()
        }
    }

    private struct Offline: LocalizedError { var errorDescription: String? { "The network is offline." } }

    private var tempURL: URL!
    private var modelsDir: URL!
    private var configStore: ConfigStore!
    private var applied = 0
    private var engineModel = ModelSpec.file("/m.bin")
    private let installed = Installed(["fast"])
    private lazy var downloader = FakeDownloader(installed: installed)
    private let environment = EngineEnvironment.mac(15)
    private lazy var engines = EngineRegistry([WhisperEngine(), DownloadableEngine(installed: installed)])

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-model-download-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        modelsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-model-download-models-\(UUID().uuidString)", isDirectory: true)
        applied = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: modelsDir)
        super.tearDown()
    }

    private func makeVM(engine: EngineKind = .whisperKit, model: ModelChoice = .automatic) -> SettingsViewModel {
        configStore.update {
            $0.engine = engine.rawValue
            $0.language = "en"
            $0.setModelChoice(model, for: engine)
        }
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { [unowned self] in self.engineModel },
            modelStatus: .missing,
            onModelSettingsChange: { [weak self] in self?.applied += 1 },
            engines: engines,
            environment: environment,
            modelDownloader: downloader,
            modelsDir: modelsDir
        )
    }

    private func key(_ id: String) -> ModelDownloadKey { ModelDownloadKey(engine: .whisperKit, id: id) }

    /// Until `condition` holds (progress hops to main), or fails after ~1 s.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: -

    func testOnlyModelsThatArentInstalledOfferADownload() {
        let vm = makeVM()
        XCTAssertTrue(vm.canDownloadModel(key("big")))
        XCTAssertFalse(vm.canDownloadModel(key("fast")), "already installed")
        XCTAssertNil(vm.modelDownloadLabel(key("big")), "nothing under way")
        XCTAssertEqual(vm.inAppDownloadableModels.map(\.key), [key("big")])

        let whisper = makeVM(engine: .whisper)
        XCTAssertFalse(whisper.canDownloadModel(ModelDownloadKey(engine: .whisper, id: "small.en-q5_1")), "whisper's come by command")
        XCTAssertEqual(whisper.inAppDownloadableModels, [])
    }

    func testADownloadShowsProgressThenTheModelIsListedAsDownloaded() async {
        let vm = makeVM()
        downloader.steps = [4_200]
        downloader.holds = true

        let task = vm.downloadModel(key("big"))
        await eventually { vm.modelDownloadLabel(key("big")) == "Downloading… 42%" }
        XCTAssertFalse(vm.canDownloadModel(key("big")), "one download at a time")
        XCTAssertTrue(vm.isDownloadingModel(key("big")))
        downloader.finishHolding()
        await task?.value

        XCTAssertNil(vm.modelDownloadLabel(key("big")))
        XCTAssertNil(vm.modelDownloadError(key("big")))
        XCTAssertEqual(vm.modelLists.downloaded.map(\.id), ["fast", "big"])
        XCTAssertEqual(vm.modelLists.notDownloaded, [])
    }

    func testDownloadingTheSelectedModelReloadsTheEngine() async {
        let vm = makeVM(model: .named("big"))

        await vm.downloadModel(key("big"))?.value

        XCTAssertEqual(applied, 1)
    }

    func testDownloadingAnotherModelLeavesTheEngineAlone() async {
        let vm = makeVM(model: .automatic)   // = "fast", installed

        await vm.downloadModel(key("big"))?.value

        XCTAssertEqual(applied, 0)
    }

    func testCancellingStopsTheDownloadAndOffersItAgain() async {
        let vm = makeVM(model: .named("big"))
        downloader.holds = true
        let task = vm.downloadModel(key("big"))
        await eventually { self.downloader.started == ["big"] }

        vm.cancelModelDownload(key("big"))
        await task?.value

        XCTAssertFalse(vm.isDownloadingModel(key("big")))
        XCTAssertNil(vm.modelDownloadError(key("big")), "a cancel isn't an error")
        XCTAssertTrue(vm.canDownloadModel(key("big")))
        XCTAssertEqual(applied, 0)
    }

    func testAFailedDownloadSaysWhyAndCanBeRetried() async {
        let vm = makeVM(model: .named("big"))
        downloader.error = Offline()

        await vm.downloadModel(key("big"))?.value

        XCTAssertEqual(vm.modelDownloadError(key("big")), "Download failed: The network is offline.")
        XCTAssertTrue(vm.canDownloadModel(key("big")))
        XCTAssertEqual(applied, 0)

        downloader.error = nil
        await vm.downloadModel(key("big"))?.value
        XCTAssertNil(vm.modelDownloadError(key("big")), "cleared by the retry")
        XCTAssertEqual(applied, 1)
    }

    func testAModelThatCantBeDownloadedInAppStartsNothing() async {
        let vm = makeVM()
        XCTAssertNil(vm.downloadModel(key("fast")), "already installed")
        XCTAssertEqual(downloader.started, [])
    }

    /// The missing-model hint points at the button before the command.
    func testAMissingDownloadableModelsHintMentionsTheButton() {
        let vm = makeVM(model: .named("big"))
        engineModel = ModelSpec(path: modelsDir.appendingPathComponent("fake/big").path, sha256: nil,
                                language: "en", engine: .whisperKit)
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Not downloaded. Click Download below, or run: make fake-model FAKE=big")
    }

    // MARK: - Progress

    /// A fast download reports every chunk; Settings redraws at most ~1% or
    /// 0.1 s apart, not once per chunk.
    func testProgressIsThrottled() async {
        let vm = makeVM()
        downloader.steps = Array(1...10_000)
        downloader.holds = true
        var changes = 0
        let watch = vm.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        let task = vm.downloadModel(key("big"))
        await eventually { vm.modelDownloadLabel(key("big")) == "Downloading… 100%" }
        downloader.finishHolding()
        await task?.value

        XCTAssertLessThan(changes, 200, "not one redraw per chunk")
    }

    func testProgressNeverGoesBackwards() async {
        let vm = makeVM()
        downloader.steps = [5_000, 1_000]
        downloader.holds = true

        let task = vm.downloadModel(key("big"))
        await eventually { vm.modelDownloadLabel(key("big")) == "Downloading… 50%" }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.modelDownloadLabel(key("big")), "Downloading… 50%")
        downloader.finishHolding()
        await task?.value
    }

    // MARK: - Engine switch

    /// A download keeps running when Settings switches engine: it stays
    /// listed (with its engine's name) and can still be cancelled.
    func testADownloadOfAnotherEngineStaysListedAndCancellable() async {
        let vm = makeVM(model: .named("big"))
        downloader.holds = true
        let task = vm.downloadModel(key("big"))
        await eventually { self.downloader.started == ["big"] }

        vm.selectEngine(.engine(.whisper))

        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.inAppDownloadableModels.map(\.key), [key("big")])
        XCTAssertEqual(vm.inAppDownloadableModels.first?.label, "Big — WhisperKit (Core ML)")
        XCTAssertTrue(vm.isDownloadingModel(key("big")))
        vm.cancelModelDownload(key("big"))
        await task?.value
        XCTAssertFalse(vm.isDownloadingModel(key("big")))
        XCTAssertEqual(vm.inAppDownloadableModels, [], "whisper has no Download rows")
    }

    // MARK: - Partial downloads

    /// Cancel keeps `<id>.part/` to resume from; the row offers to discard it.
    func testAPartialDownloadCanBeDiscarded() throws {
        let vm = makeVM()
        XCTAssertFalse(vm.hasPartialDownload(key("big")))
        let part = modelsDir.appendingPathComponent("fake/big.part", isDirectory: true)
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: part.appendingPathComponent("w.bin"))
        XCTAssertTrue(vm.hasPartialDownload(key("big")))

        vm.discardPartialDownload(key("big"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(vm.hasPartialDownload(key("big")))
    }
}
