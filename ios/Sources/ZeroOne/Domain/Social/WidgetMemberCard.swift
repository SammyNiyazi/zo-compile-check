import Foundation

/// Study 36 Club card widget: the root copies this into the widget snapshot.
/// Only the card's own facts (name, number, workouts) leave the Club store.
enum WidgetMemberCard {
    static let key = "01.widget.memberCard"

    static func save(_ me: ClubSelf?, defaults: UserDefaults = .standard) {
        guard let me, let number = me.person.memberNo, !me.suspended else {
            defaults.removeObject(forKey: key)
            return
        }
        let card = DailyWidgetSnapshot.Card(holderName: me.person.displayName,
                                            number: ClubPerson.memberNumber(number), workouts: me.workoutsCount)
        if let data = try? JSONEncoder().encode(card) { defaults.set(data, forKey: key) }
    }

    static func load(defaults: UserDefaults = .standard) -> DailyWidgetSnapshot.Card? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(DailyWidgetSnapshot.Card.self, from: $0) }
    }
}
