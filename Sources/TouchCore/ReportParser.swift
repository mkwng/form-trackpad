import Foundation

/// Decodes the Kinesis Form's multi-touch input report (report ID 8, 24 bytes):
///
///     [0]      report ID
///     [1..20]  four finger slots of five bytes: flags, x (16-bit LE), y (16-bit LE)
///              flags: bit 0 confidence, bit 1 touching, bits 2-5 contact ID
///     [21..22] scan time, 100 µs units
///     [23]     bits 0-3 contact count, bits 4-6 buttons
///
/// Coordinates are in tenths of a millimetre (x up to 65.0 mm, y up to 106.5 mm per the descriptor).
public enum FormReport {
    public static let reportID: UInt8 = 8
    public static let length = 24
    public static let slots = 4
    public static let unitsPerMillimetre = 10.0

    public struct Parsed: Equatable {
        public var contacts: [Contact]
        public var scanTime: UInt16
        public var buttons: UInt8
    }

    public static func parse(_ bytes: [UInt8]) -> Parsed? {
        guard bytes.count >= length, bytes[0] == reportID else { return nil }
        let count = min(Int(bytes[23] & 0x0f), slots)
        var contacts: [Contact] = []
        for slot in 0..<count {
            let o = 1 + slot * 5
            let flags = bytes[o]
            let x = Double(UInt16(bytes[o + 1]) | UInt16(bytes[o + 2]) << 8)
            let y = Double(UInt16(bytes[o + 3]) | UInt16(bytes[o + 4]) << 8)
            contacts.append(Contact(
                id: Int((flags >> 2) & 0x0f),
                position: Vec(x / unitsPerMillimetre, y / unitsPerMillimetre),
                touching: flags & 0x02 != 0,
                confident: flags & 0x01 != 0))
        }
        return Parsed(contacts: contacts,
                      scanTime: UInt16(bytes[21]) | UInt16(bytes[22]) << 8,
                      buttons: (bytes[23] >> 4) & 0x07)
    }
}
