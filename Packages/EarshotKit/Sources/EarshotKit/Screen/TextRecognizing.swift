import CoreGraphics
import Foundation
import Vision

/// Reads the text in an image, on the Mac. One line of text per line of the result.
public protocol TextRecognizing: Sendable {
    func recognize(_ image: CGImage) async throws -> String
}

/// Vision's `RecognizeTextRequest` at the accurate level (spec 9). Needs no permission.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(_ image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
