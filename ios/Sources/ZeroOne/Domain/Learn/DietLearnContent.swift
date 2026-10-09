import Foundation

/// Diets > Learn. DRAFTS written by Claude on 9 October 2026 at Sammy's request,
/// each an attributed summary of a named public body, in the same shape as
/// LearnCatalog. Not yet reviewed by a nutrition or medical professional:
/// the app says so on every article, and Sammy (or his reviewer) approves
/// them before any public release. Source pages checked 9 October 2026; the
/// two EFSA opinions block automated reading and were not re-read that day.
enum DietLearnCatalog {
    static let isReviewed = false

    static let lessons: [LearnLesson] = [
        LearnLesson(
            id: "diet-balanced-plate", topic: .habits,
            title: "Build the plate first",
            dek: "Most of a good diet is the same few habits, repeated.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "Base meals on starchy foods, choosing wholegrain where you can. Fill a big share of the plate with fruit and vegetables. Add a protein, some dairy or an alternative, and small amounts of unsaturated oil.",
            steps: [
                .init(id: "veg", title: "Fruit and vegetables", detail: "The NHS Eatwell Guide says at least 5 portions a day. WHO puts it at 400 g or more."),
                .init(id: "base", title: "A starchy base", detail: "Potatoes, bread, rice or pasta, higher-fibre or wholegrain when possible."),
                .init(id: "protein", title: "A protein", detail: "Beans, pulses, fish, eggs or meat. Fish twice a week, one of them oily.")
            ],
            questions: [
                .init(id: "limits", title: "What should I keep low?", answer: "WHO advises keeping free sugars under 10% of daily energy, salt under 5 g a day and saturated fat at no more than 10% of energy."),
                .init(id: "diet", title: "Does this fit my diet in 01?", answer: "These are general adult guidelines. A diet you follow in 01, like vegetarian or intermittent fasting, can still follow the same plate.")
            ],
            settled: "The NHS and WHO agree on plenty of fruit and vegetables, wholegrains, and limits on free sugars, salt and saturated fat.",
            open: "Exact portions depend on your body, training and goals. These guides don't set them for you.",
            safety: "If you have a medical condition, an eating disorder, or are pregnant, ask a doctor or registered dietitian what suits you.",
            sources: [
                .init(title: "The Eatwell Guide", organization: "NHS", url: URL(string: "https://www.nhs.uk/live-well/eat-well/food-guidelines-and-food-labels/the-eatwell-guide/")!, supports: "Fruit and vegetables, starchy foods, fish twice a week"),
                .init(title: "Healthy diet", organization: "World Health Organization", url: URL(string: "https://www.who.int/news-room/fact-sheets/detail/healthy-diet")!, supports: "400 g fruit and vegetables, limits on free sugars, salt and saturated fat")
            ]
        ),
        LearnLesson(
            id: "diet-water", topic: .habits,
            title: "Water, without the guesswork",
            dek: "A daily guide, then more when you sweat.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "The NHS suggests 6 to 8 cups or glasses of fluid a day as a guide, and more when you're active for long periods, in heat or unwell. EFSA's adequate intake of total water, food included, is 2.0 L a day for women and 2.5 L for men.",
            steps: [
                .init(id: "base", title: "Start with the guide", detail: "6 to 8 glasses a day. Water, milk and sugar-free drinks all count."),
                .init(id: "train", title: "Add for training", detail: "Drink extra after sweating. Water is the simplest way to replace it."),
                .init(id: "check", title: "Check the colour", detail: "The NHS says to aim for pale urine.")
            ],
            questions: [
                .init(id: "goal", title: "Where does my water goal come from?", answer: "01 starts it at 30 ml per kg of your weight, between 1.5 and 3 L. That's 01's starting point, not a figure from these sources. Change it any time."),
                .init(id: "juice", title: "Does juice count?", answer: "Yes, but the NHS limits fruit juice and smoothies to 150 ml a day in total.")
            ],
            settled: "Public guidance gives a daily fluid guide and says to drink more with long activity, heat or illness.",
            open: "How much you need on a given day depends on your size, the weather and how much you sweat.",
            safety: "If you have a heart or kidney condition, follow your doctor's fluid advice instead.",
            sources: [
                .init(title: "Water, drinks and hydration", organization: "NHS", url: URL(string: "https://www.nhs.uk/live-well/eat-well/food-guidelines-and-food-labels/water-drinks-nutrition/")!, supports: "6 to 8 glasses a day, more with activity, heat or illness"),
                .init(title: "Dietary reference values for water", organization: "European Food Safety Authority", url: URL(string: "https://www.efsa.europa.eu/en/efsajournal/pub/1459")!, supports: "Adequate intake of total water: 2.0 L women, 2.5 L men")
            ]
        ),
        LearnLesson(
            id: "diet-protein", topic: .habits,
            title: "Protein, the plain numbers",
            dek: "A reference figure, and where it stops.", minutes: 2,
            evidence: .researchSummary,
            shortVersion: "EFSA's population reference intake for adults is 0.83 g of protein per kg of body weight a day. Beans, pulses, fish, eggs, meat and dairy are all good sources.",
            steps: [
                .init(id: "spread", title: "Spread it out", detail: "A protein food at each meal is an easy way to get there."),
                .init(id: "mix", title: "Mix your sources", detail: "Pulses are low in fat and high in fibre. The NHS says to limit red and processed meat."),
                .init(id: "steady", title: "Keep it steady", detail: "Getting there most days matters more than one big meal.")
            ],
            questions: [
                .init(id: "more", title: "Do I need more because I lift?", answer: "Some research suggests people who train hard use more. EFSA's figure is for the general adult population, and this draft does not set a higher target for you.")
            ],
            settled: "EFSA sets 0.83 g per kg body weight a day as the adult reference intake.",
            open: "The best intake for strength training is still debated. A reference figure isn't a personal target.",
            safety: "If you have kidney disease or another condition, ask a doctor or dietitian before changing your protein intake.",
            sources: [
                .init(title: "Dietary reference values for protein", organization: "European Food Safety Authority", url: URL(string: "https://www.efsa.europa.eu/en/efsajournal/pub/2557")!, supports: "Adult population reference intake of 0.83 g/kg body weight per day"),
                .init(title: "Eating a balanced diet", organization: "NHS", url: URL(string: "https://www.nhs.uk/live-well/eat-well/how-to-eat-a-balanced-diet/eating-a-balanced-diet/")!, supports: "Protein sources and limiting red and processed meat")
            ]
        ),
        LearnLesson(
            id: "diet-labels", topic: .habits,
            title: "Read the label in five seconds",
            dek: "Four numbers per 100 g tell you most of it.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "Look at fat, saturates, sugars and salt per 100 g. The NHS gives the lines for high and low, and many UK labels colour them for you.",
            steps: [
                .init(id: "high", title: "High is", detail: "Per 100 g: fat over 17.5 g, saturates over 5 g, sugars over 22.5 g, salt over 1.5 g."),
                .init(id: "low", title: "Low is", detail: "Per 100 g: fat 3 g or less, saturates 1.5 g or less, sugars 5 g or less, salt 0.3 g or less."),
                .init(id: "log", title: "Then log it", detail: "When you log a food in 01, check its numbers against the label before saving.")
            ],
            questions: [
                .init(id: "between", title: "What about the middle?", answer: "Between high and low is medium. Mostly greens and ambers is a reasonable everyday choice.")
            ],
            settled: "The NHS publishes the per-100 g lines for high and low fat, saturates, sugars and salt.",
            open: "A label shows one food. Your whole day matters more than one item.",
            safety: "If you have a food allergy, always read the full ingredients list on the pack.",
            sources: [
                .init(title: "Food labels", organization: "NHS", url: URL(string: "https://www.nhs.uk/live-well/eat-well/food-guidelines-and-food-labels/how-to-read-food-labels/")!, supports: "Per-100 g high and low thresholds")
            ]
        ),
        LearnLesson(
            id: "diet-supplements-medicines", topic: .habits,
            title: "Supplements and medicines: check first",
            dek: "Food comes first. Tracking is not advice.", minutes: 2,
            evidence: .publicGuidance,
            shortVersion: "The NHS says most people get the nutrients they need from a varied, balanced diet. One common exception: everyone should consider 10 micrograms of vitamin D a day in autumn and winter.",
            steps: [
                .init(id: "food", title: "Food first", detail: "A supplement fills a gap. It doesn't replace the plate."),
                .init(id: "dose", title: "Know the limit", detail: "The NHS says adults should not take more than 100 micrograms (4,000 IU) of vitamin D a day."),
                .init(id: "ask", title: "Ask a pharmacist", detail: "Pharmacists can advise on how to use your medicines and on side effects.")
            ],
            questions: [
                .init(id: "tracker", title: "What does the tracker in 01 do?", answer: "It records what you took, at the times you set. It never suggests a dose, a new medicine or a change to one you take.")
            ],
            settled: "The NHS advises a varied diet first and 10 micrograms of vitamin D a day in autumn and winter.",
            open: "Whether you need any other supplement depends on you. This draft doesn't decide that.",
            safety: "Never start, stop or change a medicine because of an app. Talk to your doctor or pharmacist first.",
            sources: [
                .init(title: "Vitamins and minerals", organization: "NHS", url: URL(string: "https://www.nhs.uk/conditions/vitamins-and-minerals/")!, supports: "Most nutrients from a varied, balanced diet"),
                .init(title: "Vitamin D", organization: "NHS", url: URL(string: "https://www.nhs.uk/conditions/vitamins-and-minerals/vitamin-d/")!, supports: "10 micrograms in autumn and winter; 100 microgram upper limit"),
                .init(title: "How pharmacies can help", organization: "NHS", url: URL(string: "https://www.nhs.uk/nhs-services/pharmacies/how-pharmacies-can-help/")!, supports: "Pharmacists advise on using medicines and side effects")
            ]
        )
    ].filter(\.isValid)
}
