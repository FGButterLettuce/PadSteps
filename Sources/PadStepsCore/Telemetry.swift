import Foundation

public enum PadMotion: String, Codable, Sendable {
    case idle, running, paused, countdown, stopping, vibrating, unknown
}

public struct PadTelemetry: Equatable, Sendable {
    public var steps: Int
    public var elapsedSeconds: Int
    public var speedKmh: Double
    public var distanceMetres: Int
    public var motion: PadMotion

    public init(steps: Int, elapsedSeconds: Int, speedKmh: Double = 0,
                distanceMetres: Int = 0, motion: PadMotion = .running) {
        self.steps = steps
        self.elapsedSeconds = elapsedSeconds
        self.speedKmh = speedKmh
        self.distanceMetres = distanceMetres
        self.motion = motion
    }
}

/// The UART protocol verified against a physical SPERAX_P2MAX, WLT6200.
/// No motor-control API is exposed by this library.
public enum SperaxUART {
    public static let serviceUUID = "0000fff0-0000-1000-8000-00805f9b34fb"
    public static let notifyUUID = "0000fff1-0000-1000-8000-00805f9b34fb"
    public static let queryUUID = "0000fff2-0000-1000-8000-00805f9b34fb"

    public static var statusQuery: Data {
        var bytes: [UInt8] = [0xf5, 0x07, 0x00, 0x19]
        let checksum = crc16(bytes)
        bytes += [UInt8(truncatingIfNeeded: checksum), UInt8(checksum >> 8), 0xfa]
        return Data(bytes)
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var value: UInt16 = 0xffff
        for byte in bytes {
            value ^= UInt16(byte)
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xa327 : value >> 1
            }
        }
        return value
    }

    /// Accepts a validated, unescaped frame whose length has been normalized.
    public static func telemetry(from frame: [UInt8]) -> PadTelemetry? {
        guard frame.count >= 24, frame[0] == 0xf5, frame[2] == 0,
              frame[3] == 0x19, frame.last == 0xfa else { return nil }
        let u16 = { (index: Int) in Int(frame[index]) << 8 | Int(frame[index + 1]) }
        let motion: PadMotion
        switch frame[6] {
        case 0x00, 0x02: motion = .idle
        case 0x01: motion = .paused
        case 0x10: motion = .running
        case 0x11...0x13: motion = .countdown
        case 0x0f: motion = .stopping
        case 0x50: motion = .vibrating
        default: motion = .unknown
        }
        return PadTelemetry(steps: u16(15), elapsedSeconds: u16(9),
                            speedKmh: Double(frame[17]) / 10,
                            distanceMetres: u16(11) * 10, motion: motion)
    }
}

/// Reassembles split/coalesced BLE notifications, validates CRC and unescapes.
/// The on-wire length includes escape bytes; CRC uses the logical frame length.
/// That distinction was verified with real P2 Max frames, including F0 escapes.
public struct UARTFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var rejectedFrames = 0
    public init() {}

    public mutating func append(_ data: Data) -> [[UInt8]] {
        buffer.append(contentsOf: data)
        var frames: [[UInt8]] = []
        while let start = buffer.firstIndex(of: 0xf5) {
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 2 else { return frames }
            let length = Int(buffer[1])
            guard (6...128).contains(length) else {
                buffer.removeFirst(); rejectedFrames += 1; continue
            }
            guard buffer.count >= length else { return frames }
            guard buffer[length - 1] == 0xfa else {
                buffer.removeFirst(); rejectedFrames += 1; continue
            }
            let raw = Array(buffer.prefix(length))
            buffer.removeFirst(length)
            guard var logical = unescape(raw), logical.count >= 6 else {
                rejectedFrames += 1; continue
            }
            logical[1] = UInt8(logical.count)
            let expected = UInt16(logical[logical.count - 3]) | UInt16(logical[logical.count - 2]) << 8
            guard SperaxUART.crc16(Array(logical.dropLast(3))) == expected else {
                rejectedFrames += 1; continue
            }
            frames.append(logical)
        }
        buffer.removeAll(keepingCapacity: true)
        return frames
    }

    private func unescape(_ raw: [UInt8]) -> [UInt8]? {
        var result: [UInt8] = [raw[0], raw[1]]
        var index = 2
        while index < raw.count - 1 {
            if raw[index] == 0xf0 {
                guard index + 1 < raw.count - 1, raw[index + 1] <= 0x0f else { return nil }
                result.append(0xf0 | raw[index + 1]); index += 2
            } else {
                result.append(raw[index]); index += 1
            }
        }
        result.append(0xfa)
        return result
    }
}
