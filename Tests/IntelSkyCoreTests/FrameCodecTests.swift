import Foundation
import Testing

@testable import IntelSkyCore

@Test func frameRoundTripAcrossChunks() throws {
  let first = Data(#"{"id":1}"#.utf8)
  let second = Data(#"{"id":2}"#.utf8)
  let bytes = try SkyFrameCodec().encode(first) + SkyFrameCodec().encode(second)
  var decoder = SkyFrameDecoder()

  #expect(try decoder.append(bytes.prefix(3)).isEmpty)
  let frames = try decoder.append(bytes.dropFirst(3))

  #expect(frames == [first, second])
}

@Test func rejectsOversizedFrameHeader() throws {
  let size = UInt32(SkyFrameCodec.maximumPayloadSize + 1)
  let header = Data([
    UInt8(truncatingIfNeeded: size),
    UInt8(truncatingIfNeeded: size >> 8),
    UInt8(truncatingIfNeeded: size >> 16),
    UInt8(truncatingIfNeeded: size >> 24),
  ])
  var decoder = SkyFrameDecoder()

  #expect(throws: SkyFrameError.frameTooLarge(Int(size))) {
    try decoder.append(header)
  }
}
