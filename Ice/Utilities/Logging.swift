//
//  Logging.swift
//  Ice
//

import OSLog

/// A type that encapsulates logging behavior for Ice.
struct Logger {
    /// The unified logger at the base of this logger.
    private let base: os.Logger

    /// Creates a logger for Ice using the specified category.
    init(category: String) {
        self.base = os.Logger(subsystem: Constants.bundleIdentifier, category: category)
    }

    /// Logs the given informative message to the logger.
    func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        base.info("\(text, privacy: .public)")
        #endif
    }

    /// Logs the given debug message to the logger.
    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        base.debug("\(text, privacy: .public)")
        #endif
    }

    /// Logs the given error message to the logger.
    func error(_ message: @autoclosure () -> String) {
        let text = message()
        base.error("\(text, privacy: .public)")
    }

    /// Logs the given warning message to the logger.
    func warning(_ message: @autoclosure () -> String) {
        let text = message()
        base.warning("\(text, privacy: .public)")
    }
}
