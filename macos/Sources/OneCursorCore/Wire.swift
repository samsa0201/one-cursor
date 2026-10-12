import Foundation

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: return "message truncated"
        case .invalid(let s): return s
        }
    }
}

/// Big-endian writer matching Barrier's `ProtocolUtil::writef` encoding.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }

    public mutating func u16(_ v: Int) {
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func u32(_ v: Int) {
        data.append(UInt8(truncatingIfNeeded: v >> 24))
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func raw(_ d: Data) { data.append(d) }

    public mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

    /// `%s`: 4 byte length followed by the bytes.
    public mutating func string(_ d: Data) {
        u32(d.count)
        data.append(d)
    }

    public mutating func string(_ s: String) { string(Data(s.utf8)) }

    /// `%4I`: 4 byte element count followed by 4 byte integers.
    public mutating func intList(_ values: [Int]) {
        u32(values.count)
        values.forEach { u32($0) }
    }
}

/// Big-endian reader, the inverse of `ByteWriter`.
public struct ByteReader {
    private let bytes: [UInt8]
    private var pos: Int

    public init(_ data: Data, offset: Int = 0) {
        bytes = [UInt8](data)
        pos = offset
    }

    public var remaining: Int { bytes.count - pos }

    private func need(_ n: Int) throws {
        if remaining < n { throw ProtocolError.truncated }
    }

    public mutating func u8() throws -> Int {
        try need(1)
        defer { pos += 1 }
        return Int(bytes[pos])
    }

    public mutating func u16() throws -> Int {
        try need(2)
        defer { pos += 2 }
        return Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
    }

    /// Signed 16 bit value (positions, sizes and deltas).
    public mutating func s16() throws -> Int {
        Int(Int16(bitPattern: UInt16(try u16())))
    }

    /// Unsigned 32 bit value.
    public mutating func u32() throws -> Int {
        try need(4)
        defer { pos += 4 }
        return Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
    }

    public mutating func raw(_ n: Int) throws -> Data {
        try need(n)
        defer { pos += n }
        return Data(bytes[pos..<pos + n])
    }

    public mutating func string() throws -> Data {
        let len = try u32()
        if len > ByteReader.maxStringLength { throw ProtocolError.invalid("string too long: \(len)") }
        return try raw(len)
    }

    public mutating func intList() throws -> [Int] {
        let n = try u32()
        if n > ByteReader.maxListLength { throw ProtocolError.invalid("list too long: \(n)") }
        return try (0..<n).map { _ in
            Int(Int32(bitPattern: UInt32(try u32())))
        }
    }

    public static let maxStringLength = 1024 * 1024
    public static let maxListLength = 1024 * 1024
}
