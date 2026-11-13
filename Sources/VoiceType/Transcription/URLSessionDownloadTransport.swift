import Foundation

/// The live `DownloadTransport`: a URLSession data task whose body is
/// streamed straight to the file (flat memory for a 1 GB weight file), with
/// `Range: bytes=<offset>-` to resume. Hugging Face redirects file downloads
/// to its CDN; the range is carried over the redirect. Ephemeral, so no
/// model bytes land in a URL cache.
final class URLSessionDownloadTransport: DownloadTransport, @unchecked Sendable {
    private let session = URLSession(configuration: .ephemeral)

    func fetch(_ url: URL, from offset: Int64, appendingTo file: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let writer = try FileWriter(file: file, offset: offset, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = writer
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// One task's delegate: writes the body to the file and resumes the
    /// fetch when the task ends. URLSession calls it on its own serial queue.
    private final class FileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
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

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var redirected = request
            if offset > 0 { redirected.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            completionHandler(redirected)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 206:
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
            default:
                failure = ModelDownloadError.http(status: status)
                completionHandler(.cancel)
            }
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
            try? handle.close()
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
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
