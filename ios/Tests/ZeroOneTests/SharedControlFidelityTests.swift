import SwiftUI
import UIKit
import XCTest
@testable import ZeroOne

@MainActor
final class SharedControlFidelityTests: XCTestCase {
    func testPressedBackgroundSelectorsExcludeDestructiveInkAndRound() {
        for variant in [ZOButtonStyle.Variant.primary, .secondary, .quiet, .step] {
            XCTAssertTrue(ZOControlFidelity.usesPressedBackground(variant))
        }
        for variant in [ZOButtonStyle.Variant.destructive, .ink, .round] {
            XCTAssertFalse(ZOControlFidelity.usesPressedBackground(variant))
        }
    }

    func testDisabledForegroundSelectorsAndFreakCascade() {
        for theme in ZOTheme.allCases {
            for variant in [ZOButtonStyle.Variant.secondary, .quiet, .destructive, .step] {
                XCTAssertTrue(ZOControlFidelity.hasDisabledForeground(variant, theme: theme))
            }
            for variant in [ZOButtonStyle.Variant.ink, .round] {
                XCTAssertFalse(ZOControlFidelity.hasDisabledForeground(variant, theme: theme))
            }
            XCTAssertEqual(ZOControlFidelity.hasDisabledForeground(.primary, theme: theme), theme != .freak)
        }
    }

    func testPressScaleAndIndependentBackgroundTiming() {
        XCTAssertEqual(ZOControlFidelity.pressScale(pressed: true, reduceMotion: false), 0.98)
        XCTAssertEqual(ZOControlFidelity.pressScale(pressed: false, reduceMotion: false), 1)
        XCTAssertEqual(ZOControlFidelity.pressScale(pressed: true, reduceMotion: true), 1)
        XCTAssertEqual(ZOControlFidelity.buttonBackgroundAnimation(.secondary, reduceMotion: false), .linear(duration: 0.12))
        XCTAssertEqual(ZOControlFidelity.buttonBackgroundAnimation(.secondary, reduceMotion: true),
            .timingCurve(0.45, 0, 0.55, 1, duration: 0.12))
        XCTAssertNil(ZOControlFidelity.buttonBackgroundAnimation(.step, reduceMotion: false))
        XCTAssertEqual(ZOControlFidelity.buttonBackgroundAnimation(.step, reduceMotion: true),
            .timingCurve(0.45, 0, 0.55, 1, duration: 0.12))
        XCTAssertNil(ZOControlFidelity.buttonForegroundAnimation(.secondary, reduceMotion: false))
        XCTAssertEqual(ZOControlFidelity.buttonForegroundAnimation(.secondary, reduceMotion: true), .linear(duration: 0.12))
        XCTAssertEqual(ZOControlFidelity.buttonForegroundAnimation(.step, reduceMotion: true),
            .timingCurve(0.45, 0, 0.55, 1, duration: 0.12))
    }

    func testTogglePropertyCurvesAndReducedMotionRetainColorWithoutTravel() {
        for reduceMotion in [false, true] {
            let seconds = reduceMotion ? 0.18 : 0.24
            XCTAssertEqual(ZOControlFidelity.toggleDuration(reduceMotion: reduceMotion), seconds)
            XCTAssertEqual(ZOControlFidelity.toggleTrackAnimation(reduceMotion: reduceMotion),
                .timingCurve(0.2, 0.9, 0.25, 1, duration: seconds))
            let thumbColor: Animation = reduceMotion
                ? .timingCurve(0.35, 0, 0.1, 1, duration: seconds) : .linear(duration: seconds)
            XCTAssertEqual(ZOControlFidelity.toggleThumbColorAnimation(reduceMotion: reduceMotion), thumbColor)
        }
        XCTAssertEqual(ZOControlFidelity.toggleThumbTravelAnimation(reduceMotion: false),
            .timingCurve(0.35, 0, 0.1, 1, duration: 0.24))
        XCTAssertNil(ZOControlFidelity.toggleThumbTravelAnimation(reduceMotion: true))
        XCTAssertNil(ZOControlFidelity.toggleDisabledOpacityAnimation(reduceMotion: false))
        XCTAssertEqual(ZOControlFidelity.toggleDisabledOpacityAnimation(reduceMotion: true),
            .timingCurve(0.2, 0.9, 0.25, 1, duration: 0.18))
    }

    func testActualActivePrimaryCascadeKeepsOnlyRetroLightGradient() {
        for theme in ZOTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(ZOControlFidelity.primaryPressedFillIsSolid(theme: theme, scheme: scheme),
                    !(theme == .retro && scheme == .light))
            }
        }
    }

    func testRoundLabelInheritsBaseButtonTypeWhileRegularLabelsUseOverrides() {
        let style = ZOControlFidelity.labelStyle(.round)
        XCTAssertEqual(style, .section)
        XCTAssertEqual(style.spec.size, 17)
        XCTAssertEqual(style.spec.lineHeight, 22)
        XCTAssertEqual(style.spec.weight, 600)
        for variant in [ZOButtonStyle.Variant.secondary, .quiet, .destructive, .ink, .step] {
            XCTAssertEqual(ZOControlFidelity.labelStyle(variant), .label)
        }
    }

    // Native layout assertions, authored on Windows and UNRUN. These do not prove hit testing.
    func testButtonRestingLayoutRetainsPrimaryRoundAndRegularMinimaAcrossThemes() {
        for theme in ZOTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let tokens = ZeroOneThemeTokens.resolve(designTheme: theme, colorScheme: scheme)
                for variant in [ZOButtonStyle.Variant.primary, .secondary, .quiet, .destructive, .ink, .round, .step] {
                    let button = Button {} label: { Text("Go") }
                        .buttonStyle(ZOButtonStyle(variant))
                        .environment(\.zeroOneTheme, tokens)
                        .environment(\.dynamicTypeSize, .large)
                    let controller = UIHostingController(rootView: button)
                    let size = controller.sizeThatFits(in: CGSize(width: 320, height: 200))
                    let minimum: CGFloat = variant == .primary ? 56 : (variant == .quiet || variant == .round ? 44 : 48)
                    XCTAssertGreaterThanOrEqual(size.height, minimum)
                    if variant == .round || variant == .step {
                        XCTAssertEqual(size.width, minimum, accuracy: 0.5)
                    }
                    if variant == .primary { XCTAssertEqual(size.width, 320, accuracy: 0.5) }
                }
                let largePrimary = Button("Go") {}
                    .buttonStyle(ZOButtonStyle(.primary))
                    .environment(\.zeroOneTheme, tokens)
                    .environment(\.dynamicTypeSize, .accessibility1)
                XCTAssertGreaterThanOrEqual(UIHostingController(rootView: largePrimary)
                    .sizeThatFits(in: CGSize(width: 320, height: 300)).height, 64)
            }
        }
    }
}
