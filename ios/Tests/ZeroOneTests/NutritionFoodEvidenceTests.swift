import CryptoKit
import Foundation
import XCTest
@testable import ZeroOne

@MainActor
final class NutritionFoodEvidenceTests: XCTestCase {
    func testLegacyUnknownEncodingAndCompletedDayHashRemainExactlyUnchanged() throws {
        let original = legacy()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let oldShape = LegacyMeal(id: original.id, title: original.title, calories: original.calories,
            proteinGrams: original.proteinGrams, carbohydrateGrams: original.carbohydrateGrams,
            fatGrams: original.fatGrams, loggedAt: original.loggedAt)
        let oldBytes = try encoder.encode([oldShape])
        XCTAssertEqual(try encoder.encode([original]), oldBytes)
        let restored = try JSONDecoder().decode([NutritionEntry].self, from: oldBytes)
        XCTAssertNil(restored.first?.foodEvidence)
        let expected = SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(NutritionDayReview.fingerprint(entries: restored, on: original.loggedAt, calendar: calendar), expected)
    }

    func testNoOpAndTitleOnlyCorrectionsPreserveImportedMacroPrecisionAndUnknowns() throws {
        let original = legacy()
        var draft = NutritionEntryDraft(entry: original)
        XCTAssertEqual(try draft.validatedEntry(id: original.id, loggedAt: original.loggedAt), original)
        draft.title = "Corrected spelling"
        let corrected = try draft.validatedEntry(id: original.id, loggedAt: original.loggedAt)
        XCTAssertEqual(corrected.proteinGrams, 12.3456789012345)
        XCTAssertNil(corrected.carbohydrateGrams)
        XCTAssertEqual(corrected.fatGrams, 0)
        XCTAssertNil(corrected.foodEvidence)
    }

    func testMassReferenceScalesConsumedTotalsAndKeepsReferenceUnknownAndZero() throws {
        var draft = referenceDraft(.per100Grams, amount: "250", unit: .grams)
        draft.proteinGrams = "12.3456789012345"
        let entry = try draft.validatedEntry()
        XCTAssertEqual(entry.calories, 500)
        XCTAssertEqual(try XCTUnwrap(entry.proteinGrams), 30.86419725308625, accuracy: 1e-12)
        XCTAssertNil(entry.carbohydrateGrams); XCTAssertEqual(entry.fatGrams, 0)
        XCTAssertEqual(entry.foodEvidence?.referenceValues?.proteinGrams, 12.3456789012345)
        XCTAssertEqual(entry.foodEvidence?.portion?.certainty, .measuredReported)
        XCTAssertEqual(entry.foodEvidence?.origin, .labelReported)
    }

    func testVolumeAndFractionalServingsUseTheirOwnExplicitReferenceUnits() throws {
        let volume = try referenceDraft(.per100Milliliters, amount: "125", unit: .milliliters).validatedEntry()
        let serving = try referenceDraft(.perServing, amount: "0,5", unit: .servings).validatedEntry()
        XCTAssertEqual(volume.calories, 250); XCTAssertEqual(volume.proteinGrams, 12.5)
        XCTAssertEqual(serving.calories, 100); XCTAssertEqual(serving.proteinGrams, 5)
        XCTAssertEqual(serving.foodEvidence?.portion?.amount, 0.5)
    }

    func testExplicitZeroCaloriesRemainDifferentFromAnEmptyRequiredField() throws {
        var draft = referenceDraft(.per100Grams, amount: "50", unit: .grams)
        draft.calories = "0"; draft.proteinGrams = "0"
        let zero = try draft.validatedEntry()
        XCTAssertEqual(zero.calories, 0); XCTAssertEqual(zero.proteinGrams, 0)
        XCTAssertNil(zero.carbohydrateGrams)
        try FoodBodyWeightImportDecoder.validateMeals([zero])
        draft.calories = ""
        XCTAssertThrowsError(try draft.validatedEntry()) { XCTAssertEqual($0 as? NutritionEntryValidationError, .caloriesRequired) }
    }

    func testReferenceCaloriesRoundOnceAndReferenceValuesRemainInspectable() throws {
        var draft = referenceDraft(.per100Grams, amount: "1", unit: .grams)
        draft.calories = "50"
        let entry = try draft.validatedEntry()
        XCTAssertEqual(entry.calories, 1)
        XCTAssertEqual(entry.foodEvidence?.referenceValues?.calories, 50)
        XCTAssertEqual(try NutritionEntryDraft(entry: entry).validatedEntry(id: entry.id, loggedAt: entry.loggedAt), entry)
    }

    func testWholePortionValuesAreNotScaledAgainByOptionalPortionMetadata() throws {
        var draft = NutritionEntryDraft(entry: legacy())
        draft.portionAmount = "250"; draft.portionUnit = .grams
        draft.portionCertainty = .estimated; draft.valueOrigin = .estimate
        let entry = try draft.validatedEntry()
        XCTAssertEqual(entry.calories, 500)
        XCTAssertEqual(entry.proteinGrams, 12.3456789012345)
        XCTAssertNil(entry.foodEvidence?.referenceValues)
        XCTAssertEqual(entry.foodEvidence?.portion?.amount, 250)
    }

    func testUnitMismatchMissingAmountAndUnknownConversionsCannotEstablishTotals() throws {
        for (basis, unit) in [(NutritionValueBasis.per100Grams, NutritionPortionUnit.milliliters),
                              (.per100Milliliters, .grams), (.perServing, .grams)] {
            XCTAssertThrowsError(try referenceDraft(basis, amount: "200", unit: unit).validatedEntry())
        }
        XCTAssertThrowsError(try referenceDraft(.perServing, amount: "", unit: .servings).validatedEntry())
    }

    func testChangingBasisClearsAnIncompatibleAmountRatherThanInventingAConversion() {
        var draft = referenceDraft(.perServing, amount: "2", unit: .servings)
        draft.valueBasis = .per100Grams; draft.prepareForBasisChange()
        XCTAssertEqual(draft.portionUnit, .grams); XCTAssertEqual(draft.portionAmount, "")
        XCTAssertEqual(draft.calories, "200"); XCTAssertEqual(draft.proteinGrams, "10")
    }

    func testInvalidAndExcessivePortionsCannotWriteOrProduceInfiniteScaledMacros() throws {
        for amount in ["0", "-1", "NaN", "inf", "10001"] {
            XCTAssertThrowsError(try referenceDraft(.per100Grams, amount: amount, unit: .grams).validatedEntry())
        }
        XCTAssertThrowsError(try referenceDraft(.perServing, amount: "10000", unit: .servings).validatedEntry())
        var draft = referenceDraft(.per100Grams, amount: "200", unit: .grams)
        draft.calories = "1"; draft.proteinGrams = "1000"
        XCTAssertThrowsError(try draft.validatedEntry())
    }

    func testReferencedEntryReopensWithReferenceValuesAndDoesNotScaleTwice() throws {
        let entry = try referenceDraft(.per100Grams, amount: "250", unit: .grams).validatedEntry()
        let draft = NutritionEntryDraft(entry: entry)
        XCTAssertEqual(draft.calories, "200"); XCTAssertEqual(draft.proteinGrams, "10.0")
        XCTAssertEqual(try draft.validatedEntry(id: entry.id, loggedAt: entry.loggedAt), entry)
    }

    func testSourceOnlyAndPortionOnlyCorrectionsInvalidateTheFinishedDayIdentity() throws {
        let original = legacy()
        let before = NutritionDayReview.fingerprint(entries: [original], on: original.loggedAt, calendar: calendar)
        var draft = NutritionEntryDraft(entry: original)
        draft.valueOrigin = .databaseReported; draft.sourceName = "Synthetic food database"
        draft.sourceRecordID = "food-1"; draft.sourceRevision = "r1"
        let sourced = try draft.validatedEntry(id: original.id, loggedAt: original.loggedAt)
        XCTAssertNotEqual(NutritionDayReview.fingerprint(entries: [sourced], on: original.loggedAt, calendar: calendar), before)
        draft = NutritionEntryDraft(entry: original); draft.portionAmount = "250"
        let portioned = try draft.validatedEntry(id: original.id, loggedAt: original.loggedAt)
        XCTAssertEqual(portioned.calories, original.calories)
        XCTAssertNotEqual(NutritionDayReview.fingerprint(entries: [portioned], on: original.loggedAt, calendar: calendar), before)
    }

    func testUntouchedSourceTextAndPreciseAmountsSurviveANoOpCorrection() throws {
        var draft = referenceDraft(.per100Grams, amount: "12.3456789012345", unit: .grams)
        draft.sourceName = "Synthetic source"; draft.sourceRecordID = "food-1"; draft.sourceRevision = "r1"
        let entry = try draft.validatedEntry()
        let originalSource = try XCTUnwrap(entry.foodEvidence?.source)
        let rawSource = NutritionSourceReference(name: "  " + originalSource.name + "\n", recordID: " food-1 ", revision: "r1\n")
        let evidence = try XCTUnwrap(entry.foodEvidence)
        let raw = NutritionEntry(id: entry.id, title: entry.title, calories: entry.calories,
            proteinGrams: entry.proteinGrams, carbohydrateGrams: entry.carbohydrateGrams, fatGrams: entry.fatGrams,
            loggedAt: entry.loggedAt, foodEvidence: NutritionFoodEvidence(origin: evidence.origin,
                valueBasis: evidence.valueBasis, portion: evidence.portion, source: rawSource, referenceValues: evidence.referenceValues))
        XCTAssertEqual(try NutritionEntryDraft(entry: raw).validatedEntry(id: raw.id, loggedAt: raw.loggedAt), raw)
    }

    func testRecordIDOrRevisionWithoutSourceNameAndOversizedSourceAreRejected() throws {
        var draft = NutritionEntryDraft(entry: legacy()); draft.sourceRecordID = "food-1"
        XCTAssertThrowsError(try draft.validatedEntry())
        draft.sourceRecordID = ""; draft.sourceRevision = "r1"
        XCTAssertThrowsError(try draft.validatedEntry())
        draft.sourceName = String(repeating: "x", count: 513)
        XCTAssertThrowsError(try draft.validatedEntry())
    }

    func testANameOnlySourceCorrectionPreservesUntouchedExactIdentifiers() throws {
        let original = legacy()
        let evidence = NutritionFoodEvidence(origin: .databaseReported, valueBasis: .consumedPortion,
            portion: nil, source: NutritionSourceReference(name: "Original source", recordID: " id 42 ", revision: " r1 \n"),
            referenceValues: nil)
        let sourced = NutritionEntry(id: original.id, title: original.title, calories: original.calories,
            proteinGrams: original.proteinGrams, carbohydrateGrams: original.carbohydrateGrams, fatGrams: original.fatGrams,
            loggedAt: original.loggedAt, foodEvidence: evidence)
        var draft = NutritionEntryDraft(entry: sourced); draft.sourceName = "Corrected source name"
        let result = try draft.validatedEntry(id: sourced.id, loggedAt: sourced.loggedAt)
        XCTAssertEqual(result.foodEvidence?.source?.recordID, " id 42 ")
        XCTAssertEqual(result.foodEvidence?.source?.revision, " r1 \n")
        XCTAssertEqual(result.proteinGrams, sourced.proteinGrams)
    }

    func testExplicitExistingUnknownEvidenceIsNotRemovedByANoOpSave() throws {
        let original = legacy()
        let explicit = NutritionEntry(id: original.id, title: original.title, calories: original.calories,
            proteinGrams: original.proteinGrams, carbohydrateGrams: original.carbohydrateGrams, fatGrams: original.fatGrams,
            loggedAt: original.loggedAt, foodEvidence: NutritionFoodEvidence(origin: .unknown,
                valueBasis: .consumedPortion, portion: nil, source: nil, referenceValues: nil))
        let saved = try NutritionEntryDraft(entry: explicit).validatedEntry(id: explicit.id, loggedAt: explicit.loggedAt)
        XCTAssertEqual(saved, explicit)
        XCTAssertEqual(NutritionDayReview.fingerprint(entries: [saved], on: saved.loggedAt, calendar: calendar),
            NutritionDayReview.fingerprint(entries: [explicit], on: explicit.loggedAt, calendar: calendar))
    }

    func testNonNumericCorrectionsPreserveAcceptedFloatingPointRoundTripDifferences() throws {
        let original = legacy()
        let evidence = NutritionFoodEvidence(origin: .labelReported, valueBasis: .per100Grams,
            portion: NutritionPortion(amount: 100, unit: .grams, certainty: .reported), source: nil,
            referenceValues: NutritionNutrientValues(calories: 500, proteinGrams: 10, carbohydrateGrams: nil, fatGrams: 0))
        let imported = NutritionEntry(id: original.id, title: original.title, calories: 500,
            proteinGrams: 10.000000000005, carbohydrateGrams: nil, fatGrams: 0, loggedAt: original.loggedAt, foodEvidence: evidence)
        try FoodBodyWeightImportDecoder.validateMeals([imported])
        for sourceChange in [false, true] {
            var draft = NutritionEntryDraft(entry: imported)
            if sourceChange { draft.sourceName = "Reported label" }
            else { draft.title = "Corrected spelling" }
            let result = try draft.validatedEntry(id: imported.id, loggedAt: imported.loggedAt)
            XCTAssertEqual(result.proteinGrams, imported.proteinGrams)
        }
    }

    func testStaleEditorCannotOverwriteAMetadataCorrectionAfterRepositoryRefresh() throws {
        let original = legacy(); let store = MealStore([original]); let repository = NutritionRepository(store: store)
        var stale = NutritionEntryDraft(entry: original); stale.title = "Old draft"
        var correction = NutritionEntryDraft(entry: original); correction.valueOrigin = .estimate
        let newer = try repository.update(id: original.id, with: correction)
        _ = try repository.readForImport()
        XCTAssertThrowsError(try repository.update(id: original.id, with: stale)) {
            XCTAssertEqual($0 as? NutritionEntryValidationError, .entryChanged)
        }
        XCTAssertEqual(store.values, [newer]); XCTAssertEqual(store.saves, 1)
    }

    func testAnUnboundReplacementDraftCannotCorrectAnExistingFoodRecord() throws {
        let original = legacy(); let store = MealStore([original]); let repository = NutritionRepository(store: store)
        var unbound = NutritionEntryDraft(); unbound.title = "Replacement"; unbound.calories = "100"
        XCTAssertThrowsError(try repository.update(id: original.id, with: unbound)) {
            XCTAssertEqual($0 as? NutritionEntryValidationError, .entryChanged)
        }
        XCTAssertEqual(store.saves, 0); XCTAssertEqual(store.values, [original])
    }

    func testRejectedMetadataCorrectionKeepsAcknowledgedFactsAndDoesNotReplayCallbacks() throws {
        let original = legacy(); let store = MealStore([original]); var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        var correction = NutritionEntryDraft(entry: original); correction.valueOrigin = .estimate
        store.rejectWrites = true
        XCTAssertThrowsError(try repository.update(id: original.id, with: correction))
        XCTAssertEqual(repository.entries, [original]); XCTAssertEqual(callbacks, 0)
        store.rejectWrites = false
        let corrected = try repository.update(id: original.id, with: correction)
        XCTAssertEqual(corrected.foodEvidence?.origin, .estimate); XCTAssertEqual(callbacks, 0)
    }

    func testLandedButUnreadableCorrectionReconcilesWithoutRewritingOrClaimingLearning() throws {
        let original = legacy(); let store = MealStore([original]); var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        var correction = NutritionEntryDraft(entry: original); correction.valueOrigin = .estimate
        store.failReadsAfterWrite = true
        XCTAssertThrowsError(try repository.update(id: original.id, with: correction))
        XCTAssertEqual(repository.availability, .unavailable); XCTAssertEqual(repository.entries, [original])
        store.readsFail = false; store.failReadsAfterWrite = false
        let fresh = try repository.readForImport()
        XCTAssertEqual(fresh.first?.foodEvidence?.origin, .estimate)
        XCTAssertEqual(store.saves, 1); XCTAssertEqual(callbacks, 0)
    }

    func testLegacyStoreReadPreservesBytesAndFirstAcknowledgedWriteUsesProtectedEnvelope() throws {
        let suite = "FoodEvidence-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = legacy(); let bytes = try JSONEncoder().encode([original]); defaults.set(bytes, forKey: "meals")
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "meals")
        XCTAssertEqual(try store.loadVerified(), [original]); XCTAssertEqual(defaults.data(forKey: "meals"), bytes)
        let repository = NutritionRepository(store: store)
        var correction = NutritionEntryDraft(entry: original); correction.valueOrigin = .estimate
        let updated = try repository.update(id: original.id, with: correction)
        let protected = try XCTUnwrap(defaults.data(forKey: "meals"))
        XCTAssertThrowsError(try JSONDecoder().decode([LegacyMeal].self, from: protected))
        XCTAssertEqual(try store.loadVerified(), [updated])
        XCTAssertEqual(NutritionRepository(store: store).entries, [updated])
    }

    func testUnknownFutureStoreEnvelopeCannotBeOverwrittenAndLastReadableStateSurvives() throws {
        let suite = "FoodEvidence-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = legacy(); defaults.set(try JSONEncoder().encode([original]), forKey: "meals")
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "meals")
        let repository = NutritionRepository(store: store)
        let future = try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "entries": []])
        defaults.set(future, forKey: "meals")
        XCTAssertThrowsError(try repository.readForImport())
        store.save([original])
        XCTAssertEqual(defaults.data(forKey: "meals"), future)
        XCTAssertEqual(repository.entries, [original]); XCTAssertEqual(repository.availability, .unavailable)
    }

    func testSelectedExportSnapshotAndSpreadsheetPreserveNestedEvidenceAndPrecision() throws {
        var draft = referenceDraft(.per100Grams, amount: "12.3456789012345", unit: .grams)
        draft.sourceName = "=Synthetic, source\nsecond line"; draft.sourceRecordID = "food-1"; draft.sourceRevision = "r1"
        let entry = try draft.validatedEntry()
        let data = try LocalDataExport(nutritionStore: MealStore([entry]), hydrationStore: WaterStore())
            .createJSON(selection: mealSelection, exportedAt: entry.loggedAt)
        let decoded = try FoodBodyWeightImportDecoder.decode(data, category: .meals)
        XCTAssertEqual(decoded.schemaVersion, LocalDataExportPackage.currentSchemaVersion); XCTAssertEqual(decoded.meals, [entry])
        let files = try LocalDataExportFiles.make(from: data)
        XCTAssertEqual(files["snapshot.json"], data)
        let csv = String(decoding: try XCTUnwrap(files["meals.csv"]), as: UTF8.self)
        XCTAssertTrue(csv.contains("foodEvidence.portion.amount")); XCTAssertTrue(csv.contains("12.3456789012345"))
        XCTAssertTrue(csv.contains("foodEvidence.referenceValues.proteinGrams"))
        XCTAssertTrue(csv.contains("'=Synthetic, source\nsecond line"), "Spreadsheet formula safety must not alter snapshot text")
        XCTAssertEqual(decoded.meals.first?.foodEvidence?.source?.name, draft.sourceName)
    }

    func testUnknownLocalFieldsCannotBeDroppedByAFollowingSave() throws {
        let suite = "FoodEvidence-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "meals")
        let original = legacy()
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var unknownRow = row; unknownRow["futureField"] = "Preserve this unknown fact"
        for object in [[unknownRow] as Any, ["schemaVersion": 1, "entries": [row], "futureField": true] as Any] {
            let bytes = try JSONSerialization.data(withJSONObject: object); defaults.set(bytes, forKey: "meals")
            XCTAssertThrowsError(try store.loadVerified())
            store.save([original])
            XCTAssertEqual(defaults.data(forKey: "meals"), bytes)
        }
    }

    func testDuplicateLocalJSONKeysCannotEstablishWhichNutrientValueWasSaved() throws {
        let suite = "FoodEvidence-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = legacy()
        let bytes = Data("[{\"id\":\"\(original.id.uuidString)\",\"title\":\"Synthetic food\",\"calories\":500,\"calories\":100,\"loggedAt\":812345600}]".utf8)
        defaults.set(bytes, forKey: "meals")
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "meals")
        XCTAssertThrowsError(try store.loadVerified()); store.save([original])
        XCTAssertEqual(defaults.data(forKey: "meals"), bytes)
    }

    func testExportUsesThrowingReadAndRejectsInvalidMetadataInsteadOfAnEmptyFallback() throws {
        let store = MealStore([legacy()]); store.readsFail = true
        let export = LocalDataExport(nutritionStore: store, hydrationStore: WaterStore())
        XCTAssertThrowsError(try export.createJSON(selection: mealSelection)) {
            XCTAssertEqual($0 as? LocalDataExportError, .nutritionUnavailable)
        }
        XCTAssertEqual(store.legacyLoads, 0)
        store.readsFail = false
        let original = legacy()
        store.values = [NutritionEntry(id: original.id, title: original.title, calories: original.calories,
            proteinGrams: original.proteinGrams, carbohydrateGrams: original.carbohydrateGrams, fatGrams: original.fatGrams,
            loggedAt: original.loggedAt, foodEvidence: NutritionFoodEvidence(schemaVersion: 99, origin: .estimate,
                valueBasis: .consumedPortion, portion: nil, source: nil, referenceValues: nil))]
        XCTAssertThrowsError(try export.createJSON(selection: mealSelection))
    }

    func testStrictImportRejectsNestedUnknownKeysAndUnknownEvidenceVersions() throws {
        let entry = try referenceDraft(.per100Grams, amount: "100", unit: .grams).validatedEntry()
        for (objectPath, key, value) in [("", "schemaVersion", 99 as Any), ("", "origin", "verified" as Any),
                                        ("", "newField", true as Any), ("portion", "density", 1 as Any),
                                        ("source", "apiKey", "synthetic" as Any), ("referenceValues", "sodium", 1 as Any)] {
            let data = try changingEvidence(package([entry]), path: objectPath, key: key, value: value)
            XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(data, category: .meals))
        }
    }

    func testImportRejectsIncoherentScaledTotalsAndOlderHeaderClaimingNewEvidence() throws {
        let entry = try referenceDraft(.per100Grams, amount: "250", unit: .grams).validatedEntry()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package([entry])) as? [String: Any])
        var rows = try XCTUnwrap(object["meals"] as? [[String: Any]]); rows[0]["calories"] = 200; object["meals"] = rows
        XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(JSONSerialization.data(withJSONObject: object), category: .meals))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: package([entry])) as? [String: Any])
        object["schemaVersion"] = 3
        XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(JSONSerialization.data(withJSONObject: object), category: .meals))
    }

    func testMetadataOnlyIdentifierConflictAndPendingImportChangesBlockWithoutWrites() throws {
        let original = legacy(); let store = MealStore([original]); let repository = NutritionRepository(store: store)
        let coordinator = FoodBodyWeightImportCoordinator(category: .meals, nutrition: repository,
            bodyWeight: BodyWeightRepository(store: WeightStore()), canImport: { true })
        var changed = NutritionEntryDraft(entry: original); changed.valueOrigin = .estimate
        let conflicting = try changed.validatedEntry(id: original.id, loggedAt: original.loggedAt)
        XCTAssertThrowsError(try coordinator.prepare(data: package([conflicting]))) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .conflictingIdentifier)
        }
        let incoming = try referenceDraft(.perServing, amount: "1", unit: .servings).validatedEntry()
        let review = try coordinator.prepare(data: package([incoming]))
        store.values = [conflicting]
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .storeChanged)
        }
        XCTAssertEqual(store.values, [conflicting]); XCTAssertEqual(store.saves, 0)
    }

    func testActualImportAndRelaunchPreserveEvidenceWithoutReplayingEatingCallbacks() throws {
        let suite = "FoodEvidence-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "meals"); var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        let coordinator = FoodBodyWeightImportCoordinator(category: .meals, nutrition: repository,
            bodyWeight: BodyWeightRepository(store: WeightStore()), canImport: { true })
        let entry = try referenceDraft(.per100Milliliters, amount: "125.5", unit: .milliliters).validatedEntry()
        let review = try coordinator.prepare(data: package([entry]))
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(try store.loadVerified(), [entry]); XCTAssertEqual(NutritionRepository(store: store).entries, [entry])
        XCTAssertEqual(callbacks, 0)
    }

    func testLegacyTransferVersionsRemainReadableAndNewVersionDoesNotBlockWorkoutCategory() throws {
        let original = legacy()
        for version in [2, 3] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package([original])) as? [String: Any])
            object["schemaVersion"] = version
            let decoded = try FoodBodyWeightImportDecoder.decode(JSONSerialization.data(withJSONObject: object), category: .meals)
            XCTAssertEqual(decoded.meals, [original]); XCTAssertNil(decoded.meals.first?.foodEvidence)
        }
        let data = try JSONEncoder().encode(LocalDataExportPackage(exportedAt: original.loggedAt,
            completedWorkouts: [], bodyWeightReadings: [],
            selection: .init(workouts: true, mealsAndWater: true, outdoorActivities: false, goalsAndPreferences: false),
            meals: [original], waterSnapshot: nil, outdoorActivities: nil, goalsAndPreferences: nil))
        XCTAssertNoThrow(try WorkoutHistoryImportDecoder.decode(data))
    }

    func testEvidenceQualityDoesNotTurnReportedDatabaseValuesIntoVerifiedIntake() throws {
        var estimate = NutritionEntryDraft(entry: legacy()); estimate.valueOrigin = .estimate
        estimate.portionAmount = "200"; estimate.portionCertainty = .estimated
        let reported = try referenceDraft(.perServing, amount: "1", unit: .servings).validatedEntry()
        let summary = NutritionLoggedEvidenceSummary(entries: [legacy(), try estimate.validatedEntry(), reported])
        XCTAssertEqual(summary.entryCount, 3); XCTAssertEqual(summary.unknownOriginCount, 1)
        XCTAssertEqual(summary.estimatedValueCount, 1); XCTAssertEqual(summary.reportedSourceCount, 1)
        XCTAssertEqual(summary.estimatedPortionCount, 1); XCTAssertEqual(summary.unknownPortionCount, 1)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var mealSelection: LocalDataExportSelection {
        .init(workouts: false, mealsAndWater: true, bodyWeight: false, outdoorActivities: false, goalsAndPreferences: false)
    }
    private func legacy() -> NutritionEntry {
        NutritionEntry(id: UUID(), title: "Synthetic food", calories: 500, proteinGrams: 12.3456789012345,
            carbohydrateGrams: nil, fatGrams: 0, loggedAt: Date(timeIntervalSinceReferenceDate: 812345600))
    }
    private func referenceDraft(_ basis: NutritionValueBasis, amount: String, unit: NutritionPortionUnit) -> NutritionEntryDraft {
        var value = NutritionEntryDraft(); value.title = "Synthetic labelled food"; value.calories = "200"
        value.proteinGrams = "10"; value.fatGrams = "0"; value.valueOrigin = .labelReported
        value.valueBasis = basis; value.portionAmount = amount; value.portionUnit = unit
        value.portionCertainty = .measuredReported; value.sourceName = "Synthetic label"
        return value
    }
    private func package(_ entries: [NutritionEntry]) throws -> Data {
        try JSONEncoder().encode(LocalDataExportPackage(exportedAt: Date(timeIntervalSinceReferenceDate: 812345700),
            completedWorkouts: [], bodyWeightReadings: [], selection: mealSelection,
            meals: entries, waterSnapshot: nil, outdoorActivities: nil, goalsAndPreferences: nil))
    }
    private func changingEvidence(_ data: Data, path: String, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(object["meals"] as? [[String: Any]])
        var evidence = try XCTUnwrap(rows[0]["foodEvidence"] as? [String: Any])
        if path.isEmpty { evidence[key] = value }
        else {
            var nested = try XCTUnwrap(evidence[path] as? [String: Any]); nested[key] = value; evidence[path] = nested
        }
        rows[0]["foodEvidence"] = evidence; object["meals"] = rows
        return try JSONSerialization.data(withJSONObject: object)
    }
    private struct LegacyMeal: Codable {
        let id: UUID; let title: String; let calories: Int; let proteinGrams: Double?
        let carbohydrateGrams: Double?; let fatGrams: Double?; let loggedAt: Date
    }
    private final class MealStore: NutritionPersisting {
        var values: [NutritionEntry]; var saves = 0; var legacyLoads = 0
        var readsFail = false; var rejectWrites = false; var failReadsAfterWrite = false
        var isAvailable: Bool { !readsFail }
        init(_ values: [NutritionEntry]) { self.values = values }
        func load() -> [NutritionEntry] { legacyLoads += 1; return readsFail ? [] : values }
        func loadVerified() throws -> [NutritionEntry] {
            if readsFail { throw CocoaError(.fileReadCorruptFile) }; return values
        }
        func save(_ entries: [NutritionEntry]) {
            saves += 1; if rejectWrites { return }; values = entries
            if failReadsAfterWrite { readsFail = true }
        }
    }
    private struct WeightStore: BodyWeightPersisting {
        func load() throws -> [BodyWeightEntry] { [] }
        func save(_ entries: [BodyWeightEntry]) throws { XCTFail("Unselected weight must not be written") }
    }
    private struct WaterStore: HydrationPersisting {
        func load() -> HydrationStoredState? { nil }
        func save(_ state: HydrationStoredState) { XCTFail("Export must not write water") }
    }
}
