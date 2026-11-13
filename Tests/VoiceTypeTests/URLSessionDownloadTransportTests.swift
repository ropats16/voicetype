import XCTest
@testable import VoiceType

/// The live download transport (`URLSessionDownloadTransport`) over a stub
/// URL protocol, no network: resuming with a Range only appends the bytes the
/// server says start at the offset, and a cancel always ends the fetch.
final class URLSessionDownloadTransportTests: XCTestCase {

    /// Answers each request with `StubHTTP.respond(request)`; records them.
    final class StubHTTP: URLProtocol {
        struct Reply {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data()
            /// Never answers (until the task is cancelled).
            var hangs = false
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var _respond: (URLRequest) -> Reply = { _ in Reply(status: 404) }
        nonisolated(unsafe) private static var _requests: [URLRequest] = []

        static var respond: (URLRequest) -> Reply {
            get { lock.withLock { _respond } }
            set { lock.withLock { _respond = newValue } }
        }
        static var requests: [URLRequest] { lock.withLock { _requests } }
        static func reset() { lock.withLock { _requests = []; _respond = { _ in Reply(status: 404) } } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self._requests.append(request) }
            let reply = Self.respond(request)
            guard !reply.hangs else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var file: URL!
    private let url = URL(string: "https://hf.test/org/m/resolve/abc/weight.bin")!
    private let body = Data((0..<300).map { UInt8($0 % 251) })

    private lazy var transport: URLSessionDownloadTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSessionDownloadTransport(configuration: configuration)
    }()

    override func setUp() {
        super.setUp()
        StubHTTP.reset()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("transport-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        StubHTTP.reset()
        super.tearDown()
    }

    /// Serves `body`, honouring `Range: bytes=<n>-` with a correct 206.
    private func serveRanges() {
        StubHTTP.respond = { [body] request in
            guard let range = request.value(forHTTPHeaderField: "Range") else { return .init(status: 200, body: body) }
            let start = Int(range.dropFirst("bytes=".count).dropLast())!
            return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                         body: body.dropFirst(start))
        }
    }

    func testResumesFromTheOffsetWithARange() async throws {
        serveRanges()
        try body.prefix(120).write(to: file)

        try await transport.fetch(url, from: 120, appendingTo: file) { _ in }

        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(StubHTTP.requests.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=120-"])
    }

    /// A 206 that starts somewhere else (a CDN ignoring part of the range)
    /// mustn't be appended: the file starts over from zero.
    func testA206ForAnotherOffsetRestartsTheFileFromZero() async throws {
        StubHTTP.respond = { [body] request in
            guard request.value(forHTTPHeaderField: "Range") != nil else { return .init(status: 200, body: body) }
            return .init(status: 206, headers: ["Content-Range": "bytes 0-299/300"], body: body)
        }
        try body.prefix(120).write(to: file)

        try await transport.fetch(url, from: 120, appendingTo: file) { _ in }

        XCTAssertEqual(try Data(contentsOf: file), body, "not 120 bytes + the whole body again")
    }

    func testA206WithoutAContentRangeRestartsTheFileFromZero() async throws {
        StubHTTP.respond = { [body] request in
            guard request.value(forHTTPHeaderField: "Range") != nil else { return .init(status: 200, body: body) }
            return .init(status: 206, body: body.dropFirst(120))
        }
        try Data(repeating: 9, count: 120).write(to: file)   // a prefix it can't vouch for

        try await transport.fetch(url, from: 120, appendingTo: file) { _ in }

        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    /// Cancelled before it even started: no request, and it ends (no hang).
    func testAFetchCancelledBeforeItStartsThrowsCancellation() async throws {
        StubHTTP.respond = { _ in .init(status: 200, hangs: true) }
        let started = expectation(description: "fetch ended")
        let task = Task { [transport, url, file] in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await transport.fetch(url, from: 0, appendingTo: file!) { _ in }
                XCTFail("cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        _ = task
        XCTAssertEqual(StubHTTP.requests.count, 0, "nothing sent")
    }

    func testCancellingAHangingFetchEndsIt() async throws {
        StubHTTP.respond = { _ in .init(status: 200, hangs: true) }
        let task = Task { [transport, url, file] in try await transport.fetch(url, from: 0, appendingTo: file!) { _ in } }
        for _ in 0..<500 where StubHTTP.requests.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }

        task.cancel()

        do { try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
