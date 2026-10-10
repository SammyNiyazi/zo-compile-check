import Foundation

/// Exact codes.js 35-segment encoder. Only an explicitly supplied official card
/// number can be rendered by the UI. This codec grants nothing and resolves no user.
enum ProfileSettingsYouWeekCode {
    static func bits(number: String) -> [Bool]? {
        guard !number.isEmpty, number.count <= 8,
              number.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt32(number), value > 0, value <= 0xFFFFFF else { return nil }
        let bytes = [UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x07 : crc &<< 1 }
        }
        let body = ((value << 8) | UInt32(crc)) ^ 0x5A3C96E1
        return [true, true, false] + (0..<32).map { body & (1 << (31 - $0)) != 0 }
    }
}
