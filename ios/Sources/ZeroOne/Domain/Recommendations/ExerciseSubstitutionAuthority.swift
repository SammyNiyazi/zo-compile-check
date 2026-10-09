import Foundation

@MainActor
final class ExerciseSubstitutionAuthority {
    typealias Reader = @MainActor (WorkoutSession) async throws -> ExerciseSubstitutionContext
    private var reader: Reader?
    func install(_ reader: @escaping Reader) { self.reader = reader }
    func context(for session: WorkoutSession) async throws -> ExerciseSubstitutionContext {
        guard let reader else { throw ExerciseSubstitutionSelectionError.unavailable }
        return try await reader(session)
    }
}
