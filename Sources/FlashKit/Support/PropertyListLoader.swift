import Foundation

enum PropertyListLoader {
    static func dictionary(from data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return dictionary
    }

    static func integer64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        default:
            return nil
        }
    }
}
