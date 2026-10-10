import CoreGraphics

/// The cancel target sits beside the 64 pt control, with a 16 pt gap.
/// Coordinates belong to the control's local gesture space, never the screen.
enum VoiceHoldPresentation {
    static let controlSize: CGFloat = 64
    static let cancelSize: CGFloat = 44
    static let gap: CGFloat = 16


    /// Explicit opt-in keeps the frozen 64/44/16 default hit contract intact.
    struct Geometry: Equatable {
        let controlSize: CGFloat
        let cancelSize: CGFloat
        let gap: CGFloat

        static let proof = Geometry(controlSize: 60, cancelSize: 44, gap: 54)

        func cancelTarget(isRightToLeft: Bool) -> CGRect {
            CGRect(x: isRightToLeft ? controlSize + gap : -(cancelSize + gap),
                   y: (controlSize - cancelSize) / 2, width: cancelSize, height: cancelSize)
        }
    }

    static func isOnCancel(_ location: CGPoint, geometry: Geometry, isRightToLeft: Bool = false) -> Bool {
        geometry.cancelTarget(isRightToLeft: isRightToLeft).contains(location)
    }

    static func isOnCancel(_ location: CGPoint, isRightToLeft: Bool = false) -> Bool {
        let target = CGRect(x: isRightToLeft ? controlSize + gap : -(cancelSize + gap),
                            y: (controlSize - cancelSize) / 2,
                            width: cancelSize, height: cancelSize)
        return target.contains(location)
    }
}
