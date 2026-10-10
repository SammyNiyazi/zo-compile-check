import XCTest
@testable import ZeroOne

/// Proof 25: chat messages decode from the server's shape; previews say what they are.
final class ClubChatTests: XCTestCase {
    private let author = #"{"account_id":"6B1F1B7A-7E2D-4C55-9A8F-1C2D3E4F5A6B","handle":"elsa","display_name":"Elsa","member_no":7}"#

    func testATrainTogetherInviteCarriesItsAnswers() throws {
        let json = """
        {"id":"5B1F1B7A-7E2D-4C55-9A8F-1C2D3E4F5A6B","author":\(author),"mine":false,"kind":"together","body":"",
         "payload":{"title":"Upper body A","place":"Sofia Lifters gym"},"created_at":"2026-10-10T16:00:00Z",
         "answers":[{"name":"Maya","mine":false,"answer":"in"},{"name":"Theo","mine":true,"answer":"out"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ClubMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.kind, .together)
        XCTAssertEqual(message.answers.filter(\.isIn).map(\.name), ["Maya"])
        XCTAssertEqual(message.preview(.english), "Train together · Upper body A")
    }

    func testAnUnknownKindFallsBackToText() throws {
        let json = """
        {"id":"5B1F1B7A-7E2D-4C55-9A8F-1C2D3E4F5A6B","author":\(author),"kind":"voice","body":"hi",
         "payload":{},"created_at":"2026-10-10T16:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ClubMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.kind, .text)
        XCTAssertTrue(message.answers.isEmpty)
    }
}
