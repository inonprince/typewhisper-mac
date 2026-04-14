import XCTest
@testable import TypeWhisper

final class StreamingHandlerTests: XCTestCase {
    func testPreviewRequestPolicyForStreamingEnginesKeepsFastCadenceWithBoundedWindow() {
        XCTAssertEqual(
            StreamingHandler.previewRequestPolicy(supportsStreaming: true),
            .init(pollInterval: 1.5, minimumBufferDuration: 0.5, maximumBufferDuration: 15)
        )
    }

    func testPreviewRequestPolicyForNonStreamingEnginesUsesSlowerCadenceAndSmallerWindow() {
        XCTAssertEqual(
            StreamingHandler.previewRequestPolicy(supportsStreaming: false),
            .init(pollInterval: 6, minimumBufferDuration: 1.5, maximumBufferDuration: 12)
        )
    }

    func testStabilizeTextAppendsRollingWindowTail() {
        let confirmed = "hello world this is a"
        let shifted = "world this is a test"

        XCTAssertEqual(
            StreamingHandler.stabilizeText(confirmed: confirmed, new: shifted),
            "hello world this is a test"
        )
    }
}
