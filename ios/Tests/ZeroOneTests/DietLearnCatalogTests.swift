import XCTest
@testable import ZeroOne

final class DietLearnCatalogTests: XCTestCase {
    func testAllFiveDraftsAreValidSourcedAndMarkedUnreviewed() {
        XCTAssertEqual(DietLearnCatalog.lessons.map(\.id), [
            "diet-balanced-plate", "diet-water", "diet-protein", "diet-labels", "diet-supplements-medicines"
        ])
        XCTAssertFalse(DietLearnCatalog.isReviewed)
        for lesson in DietLearnCatalog.lessons {
            XCTAssertTrue(lesson.isValid, lesson.id)
            XCTAssertTrue(lesson.sources.allSatisfy { $0.url.scheme == "https" }, lesson.id)
            let text = [lesson.title, lesson.dek, lesson.shortVersion, lesson.settled, lesson.open, lesson.safety]
                + lesson.steps.flatMap { [$0.title, $0.detail] } + lesson.questions.flatMap { [$0.title, $0.answer] }
            XCTAssertFalse(text.contains { $0.contains("\u{2014}") }, "No em dashes: \(lesson.id)")
        }
        XCTAssertNil(LearnCatalog.lesson("diet-water"), "Diet drafts stay out of the training Learn catalog")
    }
}
