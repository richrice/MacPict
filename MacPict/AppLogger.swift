import Foundation
import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.macpict.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let annotation = Logger(subsystem: subsystem, category: "annotation")
    static let delivery = Logger(subsystem: subsystem, category: "delivery")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
