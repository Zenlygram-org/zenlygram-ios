import Foundation

/// Zenlygram — the two primitive formats every customer-data body, record and marker uses
/// (contract §0.3): `instant` (`YYYY-MM-DDTHH:MM:SSZ`, UTC, whole seconds, no fraction) and `uuid4`
/// (lowercase). Pure and thread-safe (`gmtime_r` / `timegm`, no shared formatter).
public enum SGCustomerTime {
    /// `date` as an `instant`; a fraction of a second is dropped, never rounded up.
    public static func instant(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            Int(parts.tm_year) + 1900,
            Int(parts.tm_mon) + 1,
            Int(parts.tm_mday),
            Int(parts.tm_hour),
            Int(parts.tm_min),
            Int(parts.tm_sec)
        )
    }

    /// The date of an `instant`, or nil for anything else (another shape, a fraction, an offset, a
    /// day or time that does not exist).
    public static func date(fromInstant text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 20,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    return nil
                }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0 ..< 4), let month = number(5 ..< 7), let day = number(8 ..< 10),
              let hour = number(11 ..< 13), let minute = number(14 ..< 16), let second = number(17 ..< 19) else {
            return nil
        }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = Int32(second)
        let date = Date(timeIntervalSince1970: TimeInterval(timegm(&parts)))
        // `timegm` normalises out-of-range fields (Feb 30, 24:00, :60); the round trip refuses them.
        guard SGCustomerTime.instant(date) == text else {
            return nil
        }
        return date
    }

    public static func isInstant(_ text: String) -> Bool {
        return SGCustomerTime.date(fromInstant: text) != nil
    }

    /// A fresh random (version 4) UUID, lowercase — a `consent_id`, an `Idempotency-Key`.
    public static func uuid4() -> String {
        return UUID().uuidString.lowercased()
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
    public static func isUUID4(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else {
            return false
        }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else {
                    return false
                }
            case 14:
                guard byte == UInt8(ascii: "4") else {
                    return false
                }
            case 19:
                guard byte == UInt8(ascii: "8") || byte == UInt8(ascii: "9") || byte == UInt8(ascii: "a") || byte == UInt8(ascii: "b") else {
                    return false
                }
            default:
                guard SGCustomerTime.isLowerHex(byte) else {
                    return false
                }
            }
        }
        return true
    }

    /// `^[0-9a-f]{64}$` (`text_sha256`, `template_sha256`).
    public static func isHex64(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy(SGCustomerTime.isLowerHex)
    }

    static func isLowerHex(_ byte: UInt8) -> Bool {
        return (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }
}
