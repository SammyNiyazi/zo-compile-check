import CoreGraphics
import Foundation

enum MainActionHoldEvent {
    case began(UUID)
    case moved(UUID, CGPoint)
    case ended(UUID, CGPoint?)
    case cancelled(UUID)
}

/// Gesture state only; no permission request, service or action execution lives here.
struct ContinuousVoiceHold {
    private(set) var id: UUID?
    private(set) var isCancelled = false
    private var frozenControlBounds = CGRect.zero
    private var frozenProofBounds = CGRect.zero
    private var frozenCancelBounds = CGRect.zero

    mutating func begin(_ id: UUID, controlBounds: CGRect, physicalRootBounds: CGRect) {
        self.id = id
        frozenControlBounds = controlBounds
        frozenProofBounds = CGRect(x: physicalRootBounds.midX - 30,
                                   y: physicalRootBounds.maxY - 82, width: 60, height: 60)
        frozenCancelBounds = CGRect(x: physicalRootBounds.midX - 128,
                                    y: physicalRootBounds.maxY - 74, width: 44, height: 44)
        isCancelled = false
    }

    func contains(_ id: UUID) -> Bool { self.id == id }

    static func visualOffset(controlBounds: CGRect, physicalRootBounds: CGRect) -> CGFloat {
        guard !controlBounds.isEmpty, !physicalRootBounds.isEmpty else { return 0 }
        return physicalRootBounds.maxY - 22 - controlBounds.maxY
    }

    func canContinue(_ candidate: UUID?, isSceneActive: Bool, isDockPresented: Bool) -> Bool {
        guard let candidate else { return false }
        return contains(candidate) && !isCancelled && isSceneActive && isDockPresented
    }

    mutating func move(_ id: UUID, to point: CGPoint) {
        guard contains(id) else { return }
        // Freeze the original host's root-space frame: presentation changes must
        // never turn a stationary finger into a synthetic drag-out.
        // The 22 pt tolerance belongs only to the pre-recognition long-press gate.
        // After recognition, any release outside the retained controls discards.
        let isOnControl = frozenControlBounds.contains(point) || frozenProofBounds.contains(point)
        isCancelled = frozenCancelBounds.contains(point) || !isOnControl
    }

    mutating func end(_ id: UUID, at point: CGPoint?) -> Bool? {
        guard contains(id) else { return nil }
        if let point { move(id, to: point) }
        let cancelled = isCancelled
        invalidate()
        return cancelled
    }

    mutating func invalidate() {
        id = nil
        isCancelled = false
    }
}
