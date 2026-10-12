import Foundation

/// Minimal logger: prints with a timestamp and forwards to an optional sink (the app's log view).
public enum Log {
    public static var sink: ((String) -> Void)?
    public static var verbose = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        sink?(line)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        if verbose { info(message()) }
    }
}
