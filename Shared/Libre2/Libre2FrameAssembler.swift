import Foundation

/// Collects one encrypted frame; incomplete, expired or oversized fragments are discarded.
struct Libre2FrameAssembler {
    private var buffer = Data()
    private var frameStartedAt = Date.distantPast

    mutating func reset() {
        buffer.removeAll()
        frameStartedAt = .distantPast
    }

    mutating func append(_ fragment: Data, now: Date = Date()) -> Data? {
        if now.timeIntervalSince(frameStartedAt) > ConstantsLibre2.maximumFragmentInterval {
            reset()
        }
        if buffer.isEmpty {
            frameStartedAt = now
        }
        guard !fragment.isEmpty, buffer.count + fragment.count <= ConstantsLibre2.encryptedFrameSize else {
            reset()
            return nil
        }

        buffer.append(fragment)
        guard buffer.count == ConstantsLibre2.encryptedFrameSize else {
            return nil
        }

        let frame = buffer
        reset()
        return frame
    }
}
