import Foundation

// Standalone verification harness: Command Line Tools do not ship XCTest.
class XCTestCase {}
var failures: [String] = []
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { failures.append("\(file):\(line): \(message)") }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { XCTFail("Values differ", file: file, line: line) } }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a == b { XCTFail("Values unexpectedly equal", file: file, line: line) } }
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { XCTFail("Expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if value { XCTFail("Expected false", file: file, line: line) } }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { XCTFail("Expected nil", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try expression(); XCTFail("Expected error", file: file, line: line) } catch {} }
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { guard let value else { XCTFail("Expected nonnil", file: file, line: line); throw NSError(domain: "Verification", code: 1) }; return value }

@main struct Verification {
    static func main() async {
        let writer = WriterTests(); let api = APITests(); let markdown = MarkdownTests()
        do {
            try markdown.testHeadingsListsAndParagraphs()
            try markdown.testInlineStylesAndLinks()
            try markdown.testFencedCodeAndUnfinishedSource()
            try markdown.testUnsupportedSyntaxNeverDropsSource()
            try markdown.testBlankLinesUnicodeAndLimits()
            try markdown.testTasksQuotesAndDivider()
            try markdown.testLegacyFormatAndDraftRoundTrip()
            try markdown.testBodyAndImageBatches()
            try markdown.testPastedComparisonTables()
            try writer.testLegacyDraftAndImageUploadExpiry()
            try writer.testViewOrderUsesPropertyIDsAndRejectsForeignDatabase()
            try writer.testMultipleImagesFollowBodyAndMissingUploadsAreRejected()
            try await api.testViewMetadataSyncReadsNoCards()
            try await api.testImageUploadUsesBinaryMultipartAndNeverCreatesAPage()
            await api.testImageUploadFailureDoesNotBecomeAnAmbiguousPageWrite()
            try writer.testLongJapaneseAndEmojiPreserveEveryCharacterAndBlankLine()
            try writer.testPayloadUsesIDsAndDoesNotInterpretTitleMarkdown()
            try writer.testProductionAndDemoAreRejected()
            writer.testRemovedTagsAndPropertiesNeverSilentlyDisappear()
            writer.testOversizedTitleRejectedWithoutMutation()
            try writer.testDatabaseURLIgnoresViewQuery()
            writer.testCacheRefreshBoundary()
            try writer.testDraftRoundTripAndSourceIsolationAndCorruption()
            try await api.testMetadataSyncNeverQueriesCardsAndPreservesColors()
        await api.testWrongCreateParentStopsBeforeNetwork()
            await api.testWrongDatabaseStopsBeforeAnyFurtherRequest()
            await api.testAmbiguousWriteIsNeverAutomaticallyRetried()
            await api.testRateLimitExposesRetryAfter()
            await api.testMultipleSourcesRequireExplicitChoice()
        } catch { XCTFail("Unexpected error: \(error)") }
        if failures.isEmpty { print("PASS: 29 verification scenarios (offline; no real Notion requests)") }
        else { for failure in failures { print(failure) }; exit(1) }
    }
}
