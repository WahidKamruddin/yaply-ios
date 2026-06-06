import Foundation

extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}

extension String {
    var iso8601Date: Date? {
        ISO8601DateFormatter().date(from: self)
    }
}
