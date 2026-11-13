import Foundation

/// The live `DownloadTransport`: a URLSession data task whose body is
/// streamed straight to the file (flat memory for a 1 GB weight file), with
/// `Range: bytes=<offset>-` to resume. Hugging Face redirects file downloads
/// to its CDN; the range is carried over the redirect. Ephemeral, so no
/// model bytes land in a URL cache.
///
/// A 206 is only appended when its `Content-Range` starts at the offset
/// asked for; any other 206 (or one without the header) restarts the file
/// from zero: bytes from elsewhere in the file would pass the size check
/// and only fail the hash, losing the whole prefix anyway.
final class URLSessionDownloadTransport: DownloadTransport, @unchecked Sendable {
    private let session: URLSession

    /// `configuration` is injectable so tests can stub the HTTP layer.
    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL, from offset: Int64, appendingTo file: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        do {
            try await fetchOnce(url, from: offset, appendingTo: file, progress: progress)
        } catch is RangeMismatch where offset > 0 {
            // The writer already emptied the file: fetch it whole.
            try await fetchOnce(url, from: 0, appendingTo: file, progress: progress)
        }
    }

    private func fetchOnce(_ url: URL, from offset: Int64, appendingTo file: URL,
                           progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let writer = try FileWriter(file: file, offset: offset, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = writer
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.start(task, resuming: continuation, cancelled: Task.isCancelled)
            }
        } onCancel: {
            writer.cancel(task)
        }
    }

    /// A 206 whose range doesn't start at the offset asked for.
    private struct RangeMismatch: Error {}

    /// One task's delegate: writes the body to the file and resumes the
    /// fetch when the task ends. URLSession calls it on its own serial
    /// queue, but `start` and `cancel` come from the caller's, so the
    /// continuation and the cancel flag are under `lock`; the continuation
    /// is taken out once, so it's resumed exactly once.
    private final class FileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancelled = false
        private var finished = false

        private let handle: FileHandle
        private let offset: Int64
        private var written: Int64
        private let progress: @Sendable (Int64) -> Void
        private var failure: Error?

        init(file: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) throws {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            self.offset = offset
            self.written = offset
            self.progress = progress
        }

        /// Starts `task`, unless the fetch was cancelled first (`cancelled`,
        /// or `cancel` already ran): then it ends at once, sending nothing.
        func start(_ task: URLSessionDataTask, resuming continuation: CheckedContinuation<Void, Error>,
                   cancelled alreadyCancelled: Bool) {
            let proceed = lock.withLock { () -> Bool in
                if alreadyCancelled { cancelled = true }
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
            guard proceed else {
                task.cancel()
                return finish(.failure(CancellationError()), resuming: continuation)
            }
            task.resume()
        }

        func cancel(_ task: URLSessionDataTask) {
            lock.withLock { cancelled = true }
            task.cancel()
        }

        /// Closes the file and resumes the fetch, the first time only.
        private func finish(_ result: Result<Void, Error>, resuming given: CheckedContinuation<Void, Error>? = nil) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard !finished else { return nil }
                finished = true
                defer { self.continuation = nil }
                return given ?? self.continuation
            }
            guard let continuation else { return }
            try? handle.close()
            continuation.resume(with: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var redirected = request
            if offset > 0 { redirected.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            completionHandler(redirected)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 200 {
            case 206:
                guard Self.rangeStart(http?.value(forHTTPHeaderField: "Content-Range")) == offset else {
                    do { try handle.truncate(atOffset: 0); written = 0; failure = RangeMismatch() } catch { failure = error }
                    return completionHandler(.cancel)
                }
                completionHandler(.allow)
            case 200:
                // The whole file, range ignored: start it over.
                if offset > 0 {
                    do { try handle.truncate(atOffset: 0); written = 0 } catch { failure = error; return completionHandler(.cancel) }
                }
                completionHandler(.allow)
            case 416:
                // Nothing past `offset`: the file is already whole (or too
                // long); the downloader's size check decides.
                completionHandler(.cancel)
            case let status:
                failure = ModelDownloadError.http(status: status)
                completionHandler(.cancel)
            }
        }

        /// The first byte of `bytes <start>-<end>/<total>`; nil if malformed.
        static func rangeStart(_ header: String?) -> Int64? {
            guard let header, header.hasPrefix("bytes ") else { return nil }
            return header.dropFirst("bytes ".count).split(separator: "-").first.flatMap { Int64($0) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                progress(written)
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<Void, Error>
            if let failure {
                result = .failure(failure)
            } else if let error = error as? URLError, error.code == .cancelled {
                // Our own cancel after a 416 ends cleanly; any other cancel is the caller's.
                let rangeDone = (task.response as? HTTPURLResponse)?.statusCode == 416
                result = rangeDone ? .success(()) : .failure(CancellationError())
            } else if let error {
                result = .failure(error)
            } else {
                result = .success(())
            }
            finish(result)
        }
    }
}
