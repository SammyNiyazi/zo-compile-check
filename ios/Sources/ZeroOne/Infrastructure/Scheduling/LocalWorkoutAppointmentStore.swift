import Foundation

struct LocalWorkoutAppointmentStore: WorkoutAppointmentPersisting {
    private let fileURL: URL?
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Slick/Scheduling", isDirectory: true)
        fileURL = root?.appendingPathComponent("appointments-v1.json")
    }

    func load() throws -> [WorkoutAppointment] {
        guard let fileURL else { throw AppointmentStoreError.unavailable }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let values = try JSONDecoder().decode([WorkoutAppointment].self, from: Data(contentsOf: fileURL))
        guard WorkoutAppointmentRepository.isValid(values) else { throw AppointmentStoreError.invalid }
        return values
    }

    func save(_ appointments: [WorkoutAppointment]) throws {
        guard let fileURL else { throw AppointmentStoreError.unavailable }
        // A present corrupt file is never replaced with a fresh default.
        _ = try load()
        guard WorkoutAppointmentRepository.isValid(appointments) else { throw AppointmentStoreError.invalid }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(appointments)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try load() == appointments else { throw AppointmentStoreError.unavailable }
    }
}
