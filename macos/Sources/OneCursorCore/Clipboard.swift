import Foundation

/// Clipboard contents in Barrier's marshalled form: `u32 count`, then per format
/// `u32 format, u32 size, bytes`. Text and HTML are UTF-8 with LF line endings.
public struct ClipboardContent: Equatable {
    public var text: String?
    public var html: String?
    /// Barrier bitmap format, passed through untouched.
    public var bitmap: Data?

    public init(text: String? = nil, html: String? = nil, bitmap: Data? = nil) {
        self.text = text
        self.html = html
        self.bitmap = bitmap
    }

    public var isEmpty: Bool { text == nil && html == nil && bitmap == nil }

    public static let formatText = 0
    public static let formatHTML = 1
    public static let formatBitmap = 2

    public func marshal() -> Data {
        var formats: [(Int, Data)] = []
        if let text { formats.append((Self.formatText, Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8))) }
        if let html { formats.append((Self.formatHTML, Data(html.utf8))) }
        if let bitmap { formats.append((Self.formatBitmap, bitmap)) }
        var w = ByteWriter()
        w.u32(formats.count)
        for (format, data) in formats {
            w.u32(format)
            w.u32(data.count)
            w.raw(data)
        }
        return w.data
    }

    public static func unmarshal(_ data: Data) throws -> ClipboardContent {
        if data.isEmpty { return ClipboardContent() }
        var r = ByteReader(data)
        var content = ClipboardContent()
        let count = try r.u32()
        for _ in 0..<count {
            let format = try r.u32()
            let size = try r.u32()
            let bytes = try r.raw(size)
            switch format {
            case formatText: content.text = String(decoding: bytes, as: UTF8.self)
            case formatHTML: content.html = String(decoding: bytes, as: UTF8.self)
            case formatBitmap: content.bitmap = bytes
            default: break
            }
        }
        return content
    }
}

/// Protocol 1.6 clipboard transfer: start mark with the decimal size, chunks of
/// at most 32 KiB and an empty end mark.
public enum ClipboardChunks {
    public static let markStart = 1
    public static let markChunk = 2
    public static let markEnd = 3
    public static let chunkSize = 32 * 1024

    public static func split(id: Int, sequence: Int, data: Data) -> [Message] {
        var msgs: [Message] = [.clipboardChunk(id: id, sequence: sequence, mark: markStart, data: Data(String(data.count).utf8))]
        var pos = data.startIndex
        while pos < data.endIndex {
            let end = min(pos + chunkSize, data.endIndex)
            msgs.append(.clipboardChunk(id: id, sequence: sequence, mark: markChunk, data: Data(data[pos..<end])))
            pos = end
        }
        msgs.append(.clipboardChunk(id: id, sequence: sequence, mark: markEnd, data: Data()))
        return msgs
    }
}

/// Reassembles DCLP chunks; returns the data when the end mark arrives.
public struct ClipboardAssembler {
    private var buffers: [Int: Data] = [:]
    private var expected: [Int: Int] = [:]

    public init() {}

    public static let maxSize = 64 * 1024 * 1024

    public mutating func add(id: Int, mark: Int, data: Data) throws -> Data? {
        switch mark {
        case ClipboardChunks.markStart:
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard let size = Int(text), size >= 0, size <= Self.maxSize else {
                throw ProtocolError.invalid("invalid clipboard size")
            }
            expected[id] = size
            buffers[id] = Data(capacity: size)
        case ClipboardChunks.markChunk:
            guard var buf = buffers[id] else { return nil }
            buf.append(data)
            if buf.count > expected[id] ?? 0 {
                buffers[id] = nil
                throw ProtocolError.invalid("clipboard data exceeds announced size")
            }
            buffers[id] = buf
        case ClipboardChunks.markEnd:
            guard let buf = buffers.removeValue(forKey: id) else { return nil }
            let size = expected.removeValue(forKey: id)
            guard buf.count == size else { throw ProtocolError.invalid("corrupted clipboard data") }
            return buf
        default:
            throw ProtocolError.invalid("unknown clipboard mark \(mark)")
        }
        return nil
    }
}
