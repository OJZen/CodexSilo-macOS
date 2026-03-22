import XCTest
@testable import CodexSilo

final class CommandRunnerTimeoutTests: XCTestCase {
    func testRunTimeoutThrowsAndReturnsPromptly() {
        let start = Date()

        XCTAssertThrowsError(
            try CommandRunner.run(
                "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 1
            )
        ) { error in
            guard case let AppError.io(message) = error else {
                return XCTFail("Expected AppError.io, got: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.contains("sleep 5"))
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0)
    }
}
