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
        ),
        // Proof 24 trend articles, drafted 10 October 2026. Sources read that day:
        // EMA Wegovy overview, NHS semaglutide, the STEP 1 body-composition abstract,
        // the 2022 NEJM time-restricted eating trial (via its PubMed summary), and
        // the FDA compounding safety page (content current as of 22 April 2026).
        LearnLesson(
            id: "diet-glp1", topic: .habits,
            title: "GLP-1 medicines",
            dek: "Ozempic, Wegovy and similar: what the trials show, and what it means if you train.", minutes: 4,
            evidence: .researchSummary,
            shortVersion: "Semaglutide is a prescription medicine: Ozempic treats type 2 diabetes, and Wegovy, at a higher dose, is for weight management alongside a reduced-calorie diet and more activity. In the main 68-week study of 1,961 adults, people lost 15% of their body weight on average, against 2% on placebo.",
            steps: [
                .init(id: "prescription", title: "Only on prescription", detail: "The NHS says to buy it from a registered pharmacy, and warns that some websites sell fake weight-loss medicines."),
                .init(id: "muscle", title: "Keep training", detail: "In a body-scan part of that study, fat mass fell 19.3% and lean mass 9.7%. Lean mass includes muscle, so lifting and enough protein are worth keeping up. Ask your prescriber what suits you."),
                .init(id: "after", title: "Plan for after", detail: "In a study reviewed by the EMA, people who kept taking it lost a further 8% over 48 weeks. People switched to placebo regained 7%.")
            ],
            questions: [
                .init(id: "same", title: "Is Wegovy the same as Ozempic?", answer: "Both contain semaglutide, at different doses and for different uses. Ozempic is for type 2 diabetes."),
                .init(id: "side", title: "What are the common side effects?", answer: "The EMA lists headache, nausea, vomiting, diarrhoea, constipation and belly pain, each in more than 1 in 10 people."),
                .init(id: "app", title: "Does 01 change my plan if I take it?", answer: "No. 01 only knows what you choose to track, and it never suggests a medicine or a dose.")
            ],
            settled: "Large studies reviewed by the EMA show far more weight loss with semaglutide than with diet and activity alone.",
            open: "How best to keep muscle while taking it, and what happens over many years, are still being studied.",
            safety: "Take it only on prescription, from a registered pharmacy. It isn't suitable for everyone, for example after acute pancreatitis. Talk to your doctor.",
            sources: [
                .init(title: "Wegovy: EPAR medicine overview", organization: "European Medicines Agency", url: URL(string: "https://www.ema.europa.eu/en/medicines/human/EPAR/wegovy")!, supports: "Use, 15% vs 2% weight loss over 68 weeks, maintenance study, common side effects"),
                .init(title: "Semaglutide", organization: "NHS", url: URL(string: "https://www.nhs.uk/medicines/semaglutide/")!, supports: "Prescription only, registered pharmacy, fake medicines online, pancreatitis"),
                .init(title: "Impact of semaglutide on body composition: STEP 1", organization: "Journal of the Endocrine Society", url: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8089287/")!, supports: "Fat mass −19.3%, lean mass −9.7% at week 68")
            ],
            grade: LearnGrade(level: .strong, claim: "Strong evidence for weight loss")
        ),
        LearnLesson(
            id: "diet-intermittent-fasting", topic: .habits,
            title: "Intermittent fasting",
            dek: "Eating in a window: what a year-long trial found.", minutes: 3,
            evidence: .researchSummary,
            shortVersion: "Intermittent fasting limits when you eat, for example only between 8:00 and 16:00. In a 12-month trial of 139 adults with obesity who all cut calories, people with the 8-hour window lost 8.0 kg on average and people without it 6.3 kg. The trial couldn't tell that difference apart from chance.",
            steps: [
                .init(id: "less", title: "It works by eating less", detail: "Both groups in the trial had the same calorie target. The window is one way to reach it."),
                .init(id: "keep", title: "Pick what you can keep", detail: "With no clear extra benefit, the best pattern is the one you can stick with."),
                .init(id: "fuel", title: "Fit training in", detail: "If you lift, keep a meal with protein close to your workout, inside your window.")
            ],
            questions: [
                .init(id: "muscle", title: "Will I lose more muscle?", answer: "In that trial, lean mass and body fat changed in line with weight, with no clear difference between the groups."),
                .init(id: "app", title: "Can I follow it in 01?", answer: "Yes. Choose it as your diet in Diets. 01 tracks what you log; it doesn't set your window or your calories.")
            ],
            settled: "Cutting calories leads to weight loss with or without a time window.",
            open: "Whether the window adds a real benefit on top wasn't settled: the 1.8 kg difference could be chance.",
            safety: "If you have diabetes, take medicines that lower blood sugar, are pregnant or have had an eating disorder, ask a doctor before fasting.",
            sources: [
                .init(title: "Calorie restriction with or without time-restricted eating in weight loss", organization: "New England Journal of Medicine (2022)", url: URL(string: "https://pubmed.ncbi.nlm.nih.gov/35443107/")!, supports: "139 adults, 12 months, −8.0 kg vs −6.3 kg, difference not significant")
            ],
            grade: LearnGrade(level: .moderate, claim: "Moderate evidence: about the same as cutting calories")
        ),
        LearnLesson(
            id: "diet-peptides", topic: .habits,
            title: "Peptides like BPC-157",
            dek: "Sold online as recovery boosters. Here's what's known.", minutes: 3,
            evidence: .publicGuidance,
            shortVersion: "BPC-157 and similar \"research peptides\" are sold online for recovery and healing. None is an approved medicine for that. The US FDA says it has found no, or only limited, safety information for the ways people take them, and some may trigger immune reactions.",
            steps: [
                .init(id: "approved", title: "Not an approved medicine", detail: "No regulator has approved these peptides to treat injuries or speed up recovery."),
                .init(id: "sport", title: "Banned in sport", detail: "The World Anti-Doping Agency prohibits BPC-157 at all times, as a substance not approved for human use."),
                .init(id: "recovery", title: "What 01 builds on", detail: "Sleep, enough protein and a sensible training load. That's what your plan and reviews look at.")
            ],
            questions: [
                .init(id: "label", title: "What does \"for research use only\" mean?", answer: "It means the product isn't meant for people. The FDA also flags impurities as a risk with these peptides.")
            ],
            settled: "No regulator has approved these peptides for recovery, and the FDA lists little or no safety information for them.",
            open: "Good trials in people are missing for the uses they're sold for.",
            safety: "Don't inject products bought online. If you compete in a tested sport, BPC-157 is a doping violation.",
            sources: [
                .init(title: "Bulk drug substances that may present significant safety risks", organization: "US Food and Drug Administration", url: URL(string: "https://www.fda.gov/drugs/human-drug-compounding/certain-bulk-drug-substances-use-compounding-may-present-significant-safety-risks")!, supports: "No or limited safety information, immunogenicity and impurity risks"),
                .init(title: "The Prohibited List", organization: "World Anti-Doping Agency", url: URL(string: "https://www.wada-ama.org/en/prohibited-list")!, supports: "BPC-157 prohibited at all times (S0, non-approved substances)")
            ],
            grade: LearnGrade(level: .limited, claim: "Limited evidence in people")
        )
    ].filter(\.isValid)
}
