import Foundation

public enum SkyFrameError: Error, Equatable, CustomStringConvertible {
  case emptyFrame
  case frameTooLarge(Int)

  public var description: String {
    switch self {
    case .emptyFrame:
      return "Sky IPC frames must not be empty"
    case .frameTooLarge(let size):
      return "Sky IPC frame is too large: \(size) bytes"
    }
  }
}

public struct SkyFrameCodec: Sendable {
  public static let maximumPayloadSize = 8 * 1024 * 1024

  public init() {}

  public func encode(_ payload: Data) throws -> Data {
    guard !payload.isEmpty else { throw SkyFrameError.emptyFrame }
    guard payload.count <= Self.maximumPayloadSize else {
      throw SkyFrameError.frameTooLarge(payload.count)
    }

    let length = UInt32(payload.count)
    var frame = Data(capacity: 4 + payload.count)
    frame.append(UInt8(truncatingIfNeeded: length))
    frame.append(UInt8(truncatingIfNeeded: length >> 8))
    frame.append(UInt8(truncatingIfNeeded: length >> 16))
    frame.append(UInt8(truncatingIfNeeded: length >> 24))
    frame.append(payload)
    return frame
  }
}

public struct SkyFrameDecoder: Sendable {
  private var buffer = Data()

  public init() {}

  public mutating func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var frames: [Data] = []

    while buffer.count >= 4 {
      let length =
        Int(buffer[buffer.startIndex])
        | (Int(buffer[buffer.startIndex + 1]) << 8)
        | (Int(buffer[buffer.startIndex + 2]) << 16)
        | (Int(buffer[buffer.startIndex + 3]) << 24)

      guard length > 0 else { throw SkyFrameError.emptyFrame }
      guard length <= SkyFrameCodec.maximumPayloadSize else {
        throw SkyFrameError.frameTooLarge(length)
      }
      guard buffer.count >= 4 + length else { break }

      frames.append(buffer.subdata(in: 4..<(4 + length)))
      buffer.removeSubrange(0..<(4 + length))
    }

    return frames
  }
}
