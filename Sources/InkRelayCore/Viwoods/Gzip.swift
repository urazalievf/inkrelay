import Foundation

/// Viwoods Cloud returns note bodies as base64 gzip. Foundation only inflates raw DEFLATE,
/// so this strips the gzip header and trailer first.
enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw GzipError.notGzip
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count >= offset + 2 else { throw GzipError.truncated }
            let extraLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + extraLength
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: NUL-terminated
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw GzipError.truncated }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard bytes.count - 8 > offset else { throw GzipError.truncated }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        do {
            return try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GzipError.corrupt(error.localizedDescription)
        }
    }

    static func decompressBase64(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw GzipError.notGzip }
        return try decompress(data)
    }
}

enum GzipError: Error, LocalizedError, Equatable {
    case notGzip
    case truncated
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notGzip: return "The note body isn't gzip data."
        case .truncated: return "The note body is truncated."
        case .corrupt(let reason): return "The note body couldn't be inflated: \(reason)."
        }
    }
}
