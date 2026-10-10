import SwiftUI
import XCTest
@testable import ZeroOne

/// Authored semantics only. Native SwiftUI layout/resource/AX execution is UNRUN.
final class ContextualHeadingSigilTests: XCTestCase {
    func testCanonicalContextTableExcludesTitleExerciseAndNestedDisplayWords() {
        let contexts: [(String, ZOThemeTextRole, ZOHeadingSigilContext, Bool)] = [
            ("header-row screen display", .display, .headRowDisplay, true),
            ("direct-scroll Welcome display", .display, .directScrollDisplay, true),
            ("direct-scroll question display", .display, .directScrollDisplay, true),
            ("exercise detail display", .display, .directScrollDisplay, true),
            ("active-set exercise zo-title", .title, .headRowDisplay, false),
            ("nested theme-preview word", .display, .nestedContent, false),
            ("nested centered success display", .display, .nestedContent, false),
            ("header card section", .section, .headRowDisplay, false),
            ("timer hero", .timerHero, .directScrollDisplay, false)
        ]
        for (name, role, context, expected) in contexts {
            for theme in ZOTheme.allCases {
                XCTAssertEqual(ZOHeadingSigilSpecification.isSelected(designTheme: theme, role: role, context: context),
                               theme == .freak && expected, name)
            }
        }
    }

    func testOnlyDisplayIsEligibleAcrossEveryTextRoleAndMatchedContext() {
        for role in ZOThemeTextRole.allCases {
            for context in [ZOHeadingSigilContext.headRowDisplay, .directScrollDisplay] {
                XCTAssertEqual(ZOHeadingSigilSpecification.isSelected(designTheme: .freak, role: role, context: context),
                               role == .display)
            }
        }
    }

    func testNormalFlowAddsBlockAndBottomMarginWithoutMovingHeadingOrigin() {
        for heading in [CGSize(width: 90, height: 48), CGSize(width: 300, height: 120)] {
            let block = ZOHeadingSigilSpecification.blockFrame(after: heading)
            let flow = ZOHeadingSigilSpecification.flowSize(after: heading)
            XCTAssertEqual(block.origin, CGPoint(x: -12, y: heading.height))
            XCTAssertEqual(block.size, CGSize(width: 150, height: 24))
            XCTAssertEqual(flow.height - block.maxY, 4)
            XCTAssertEqual(flow.height - heading.height, 28)
            XCTAssertEqual(flow.width, max(heading.width, 138))
        }
    }

    func testContainUsesViewBoxAspectRatherThanStretchingAcrossThe150PointBox() {
        let mask = ZOHeadingSigilSpecification.maskFrame(in: CGSize(width: 150, height: 24))
        XCTAssertEqual(mask, CGRect(x: 0, y: 0, width: 120, height: 24))
        XCTAssertEqual(150 - mask.maxX, 30)
        XCTAssertEqual(ZOHeadingSigilSpecification.maskFrame(in: CGSize(width: 100, height: 24)),
                       CGRect(x: 0, y: 2, width: 100, height: 20))
    }

    func testDarkChromePreservesTheCanonicalHardHorizonAt50And52Percent() {
        let stops = ZOHeadingSigilSpecification.chromeStops(colorScheme: .dark)
        XCTAssertEqual(stops.map(\.location), [0, 0.3, 0.5, 0.52, 0.8, 1])
        XCTAssertEqual(stops.map(\.rgb), [0xFFFFFF, 0xE9ECEF, 0x8D939B, 0x4D535B, 0xE9ECEF, 0xFFFFFF])
        XCTAssertEqual(ZOHeadingSigilSpecification.opacity, 1)
    }

    func testLightSigilUsesGraphiteInkGradientWithoutCardEditionNinePercentOpacity() {
        let stops = ZOHeadingSigilSpecification.chromeStops(colorScheme: .light)
        XCTAssertEqual(stops.map(\.location), [0, 0.5, 1])
        XCTAssertEqual(stops.map(\.rgb), [0x353A41, 0x0A0B0D, 0x353A41])
        XCTAssertEqual(ZOHeadingSigilSpecification.opacity, 1)
    }

    func testSharedHeadingContextClassifierDoesNotPromoteOtherTextRoles() {
        for role in ZOThemeTextRole.allCases {
            for context in ZOHeadingSigilContext.allCases {
                let expected = role == .display && (context == .headRowDisplay || context == .directScrollDisplay)
                XCTAssertEqual(role.isHeadingSigilEligible(in: context), expected)
            }
        }
    }
}
