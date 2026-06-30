import Foundation
import os

/// Thin wrapper over `os.Logger` with a stderr mirror so `swift run` shows
/// output in the terminal during development.
enum Log {
    private static let logger = Logger(subsystem: AppInfo.bundleID, category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[INFO] \(message)\n".utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[ERROR] \(message)\n".utf8))
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        #if DEBUG
        FileHandle.standardError.write(Data("[DEBUG] \(message)\n".utf8))
        #endif
    }
}
