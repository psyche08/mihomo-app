import Foundation
import CoreFoundation

/// Accept the documented direct dictionary or a single dictionary envelope.
/// Never invent a deadline when macOS omits or changes the saved configuration.
struct ProbeSessionConfiguration {
    enum Invalid: String, Error {
        case missingConfiguration = "missing_configuration"
        case invalidShape = "invalid_configuration_shape"
        case invalidDeadline = "invalid_deadline_type"
        case expiredDeadline = "expired_deadline"
        case deadlineOutOfRange = "invalid_deadline_range"
        case invalidStrictFlag = "invalid_strict_flag"
    }

    let deadline: TimeInterval
    let strictUnknown: Bool
    let wrapped: Bool

    init(options: [String: Any]?, now: TimeInterval) throws {
        guard let options else { throw Invalid.missingConfiguration }
        let config: [String: Any]
        if options["deadline"] != nil {
            config = options
            wrapped = false
        } else if options.count == 1, let value = options.values.first as? [String: Any] {
            config = value
            wrapped = true
        } else {
            throw Invalid.invalidShape
        }
        guard Set(config.keys) == Set(["deadline", "strictUnknown"]) else {
            throw Invalid.invalidShape
        }
        guard let number = config["deadline"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Invalid.invalidDeadline }
        deadline = number.doubleValue
        guard deadline.isFinite, now.isFinite, deadline <= now + 330 else {
            throw Invalid.deadlineOutOfRange
        }
        guard deadline > now else { throw Invalid.expiredDeadline }
        guard let flag = config["strictUnknown"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Invalid.invalidStrictFlag }
        strictUnknown = flag.boolValue
    }
}
