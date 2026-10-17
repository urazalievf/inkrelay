import Foundation

/// Writes a ZIP archive with stored (uncompressed) entries: all an EPUB needs, and no third-party code.
/// EPUB requires the `mimetype` entry first and uncompressed, which stored entries satisfy.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(contents)
        let offset = UInt32(data.count)
        // Local file header.
        data += le32(0x0403_4b50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
        data += le32(crc) + le32(UInt32(contents.count)) + le32(UInt32(contents.count))
        data += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + contents
        // Central directory entry.
        central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
        central += le32(crc) + le32(UInt32(contents.count)) + le32(UInt32(contents.count))
        central += le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        count += 1
    }

    func finish() -> Data {
        let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(count) + le16(count)
            + le32(UInt32(central.count)) + le32(UInt32(data.count)) + le16(0)
        return data + central + end
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
