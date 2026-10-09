import CoreGraphics
import XCTest
@testable import ZeroOne

/// Candidate tests. UNRUN: requires the Apple toolchain and the actual application target.
final class VoiceMotionPresentationTests: XCTestCase {
    func testProofCancelRectangleMirrorsAndRejectsTheGapAndVisualGrowth() {
        let geometry = VoiceHoldPresentation.Geometry.proof
        for rtl in [false, true] {
            let target = geometry.cancelTarget(isRightToLeft: rtl)
            let center = CGPoint(x: target.midX, y: target.midY)
            XCTAssertTrue(VoiceHoldPresentation.isOnCancel(center, geometry: geometry, isRightToLeft: rtl))
            XCTAssertEqual(abs(center.x - geometry.controlSize / 2), 106)
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: target.minX - 0.01, y: center.y),
                                                           geometry: geometry, isRightToLeft: rtl))
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: target.maxX + 0.01, y: center.y),
                                                           geometry: geometry, isRightToLeft: rtl))
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: center.x, y: target.minY - 0.01),
                                                           geometry: geometry, isRightToLeft: rtl))
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: center.x, y: target.maxY + 0.01),
                                                           geometry: geometry, isRightToLeft: rtl))
            XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: target.minX + 0.01, y: target.minY + 0.01),
                                                          geometry: geometry, isRightToLeft: rtl))
            XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: target.maxX - 0.01, y: target.maxY - 0.01),
                                                          geometry: geometry, isRightToLeft: rtl))
            // Inside the 1.36-scaled drawing but outside the unchanged 44 pt hit rectangle.
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: target.maxX + 4, y: center.y),
                                                           geometry: geometry, isRightToLeft: rtl))
            let gapPoint = CGPoint(x: rtl ? 87 : -27, y: 30)
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(gapPoint, geometry: geometry, isRightToLeft: rtl))
            XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: 30, y: 30),
                                                           geometry: geometry, isRightToLeft: rtl))
        }
    }

    func testOriginalCancelContractStillAcceptsTheFrozenCoordinates() {
        XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: -38, y: 32)))
        XCTAssertTrue(VoiceHoldPresentation.isOnCancel(CGPoint(x: 102, y: 32), isRightToLeft: true))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: -8, y: 32)))
        XCTAssertFalse(VoiceHoldPresentation.isOnCancel(CGPoint(x: 72, y: 32), isRightToLeft: true))
    }

    func testBarHasExactAlternateLegEndpointsAndFullCycle() {
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 0), 0.35)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 1.440), 1)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 2.880), 0.35)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 0.720), 0.675, accuracy: 0.000001)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 2.160), 0.675, accuracy: 0.000001)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 0.360),
                       VoiceMotionPresentation.barOpacity(elapsed: 2.520), accuracy: 0.000001)
        // Known cubic sample t=.25: x=.2828125, y=.15625. Distinguishes cosine/smoothstep.
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: 1.440 * 0.2828125),
                       0.35 + 0.65 * 0.15625, accuracy: 0.000001)
    }

    func testBarIsBoundedAndRisesMonotonicallyWithinTheFirstLeg() {
        var previous = 0.35
        for step in 0...100 {
            let value = VoiceMotionPresentation.barOpacity(elapsed: 1.440 * Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: -1), 0.35)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: .infinity), 1)
        XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: .nan), 1)
    }

    func testReduceMotionKeepsFullInkAndSuppressesCancelGrowth() {
        for time in [0.0, 0.360, 1.440, 2.160, 2.880] {
            XCTAssertEqual(VoiceMotionPresentation.barOpacity(elapsed: time, reduceMotion: true), 1)
        }
        XCTAssertEqual(VoiceMotionPresentation.cancelScale(isHot: true, reduceMotion: true), 1)
        XCTAssertEqual(VoiceMotionPresentation.cancelScale(isHot: false, reduceMotion: false), 1)
        XCTAssertEqual(VoiceMotionPresentation.cancelScale(isHot: true, reduceMotion: false), 1.36)
    }

    func testOwnedCancelCopyUsesTheSelectedLanguage() {
        XCTAssertEqual(VoiceMotionCopy.releaseToCancel(.english), "Let go to cancel")
        XCTAssertEqual(VoiceMotionCopy.dragToCancel(.english), "Drag here to cancel")
        let bulgarian = AppLocalization(language: .bulgarian)
        XCTAssertEqual(VoiceMotionCopy.releaseToCancel(bulgarian), "Пусни, за да отмениш")
        XCTAssertEqual(VoiceMotionCopy.dragToCancel(bulgarian), "Плъзни тук, за да отмениш")
    }
}
