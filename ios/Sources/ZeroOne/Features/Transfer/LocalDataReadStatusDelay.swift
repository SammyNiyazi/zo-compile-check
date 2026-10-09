import SwiftUI

/// Delays only the visible reading status. The feature's real busy state keeps
/// blocking confirmation immediately, and its file-read task remains unchanged.
struct LocalDataReadStatusDelay: ViewModifier {
    let isReading: Bool
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content.task(id: isReading) {
            isVisible = false
            guard isReading else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}
