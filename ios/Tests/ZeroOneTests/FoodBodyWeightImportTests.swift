import XCTest
@testable import ZeroOne

@MainActor
final class FoodBodyWeightImportTests: XCTestCase {
    func testMealsReviewIsReadOnlyAndImportPreservesIDsTimesRawValuesAndUnknownMacros() throws {
        let original = meal(title: "Existing")
        let imported = meal(title: "  Recorded title  ", protein: nil, carbohydrate: 22.123456789)
        let store = FoodImportNutritionStore([original])
        var callbackCount = 0
        let nutrition = NutritionRepository(store: store, onConfirmedAddition: { _ in callbackCount += 1 })
        let coordinator = makeCoordinator(.meals, nutrition: nutrition)
        let review = try coordinator.prepare(data: package(meals: [imported]))
        XCTAssertEqual(review.meals, [imported])
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(review.appendedCount, 1)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.values.first { $0.id == imported.id }, imported)
        XCTAssertEqual(nutrition.entries.first { $0.id == imported.id }, imported)
        XCTAssertNil(nutrition.entries.first { $0.id == imported.id }?.proteinGrams)
        XCTAssertEqual(callbackCount, 0, "Import must not label old meals as today's confirmed meal action")
        XCTAssertEqual(store.saves, 1)
    }

    func testWeightReviewAndImportPreserveDecimalWithoutBinaryConversionOrInventedSource() throws {
        let store = FoodImportWeightStore()
        let repository = BodyWeightRepository(store: store)
        let coordinator = makeCoordinator(.bodyWeight, weight: repository)
        let id = UUID()
        let exact = "82.123456789012345678901234567890123456"
        let data = rawWeightPackage(id: id, kilograms: exact, date: "812345678.1234567")
        let review = try coordinator.prepare(data: data)
        XCTAssertEqual(review.weights[0].kilograms, Decimal(string: exact))
        XCTAssertEqual(review.weights[0].id, id)
        XCTAssertEqual(review.weights[0].recordedAt.timeIntervalSinceReferenceDate, 812345678.1234567)
        XCTAssertEqual(store.saves, 0)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.values, review.weights)
        XCTAssertEqual(repository.entries, review.weights)
        XCTAssertEqual(store.saves, 1)
    }

    func testExactDuplicateRowsInSourceAndStoreSkipWithoutWrite() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let coordinator = makeCoordinator(.meals, nutrition: NutritionRepository(store: store))
        let review = try coordinator.prepare(data: package(meals: [original, original]))
        XCTAssertEqual(review.meals.count, 2)
        XCTAssertEqual(review.skippedCount, 2)
        XCTAssertEqual(review.appendedCount, 0)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.saves, 0)
    }

    func testExactDuplicateWeightsInSourceAreAddedOnce() throws {
        let imported = reading()
        let store = FoodImportWeightStore()
        let coordinator = makeCoordinator(.bodyWeight, weight: BodyWeightRepository(store: store))
        let review = try coordinator.prepare(data: package(weights: [imported, imported]))
        XCTAssertEqual(review.appendedCount, 1)
        XCTAssertEqual(review.skippedCount, 1)
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(store.values, [imported])
    }

    func testNilAndZeroMacrosWithSameIDConflictRejectsWholeCategory() throws {
        let original = meal(protein: nil)
        let conflict = meal(id: original.id, title: original.title, protein: 0)
        let store = FoodImportNutritionStore([original])
        let coordinator = makeCoordinator(.meals, nutrition: NutritionRepository(store: store))
        XCTAssertThrowsError(try coordinator.prepare(data: package(meals: [meal(), conflict]))) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .conflictingIdentifier)
        }
        XCTAssertEqual(store.values, [original])
        XCTAssertEqual(store.saves, 0)
        XCTAssertNil(coordinator.review)
    }

    func testConflictingSourceWeightIDRejectsWholeCategory() throws {
        let original = reading()
        let conflict = reading(id: original.id, kilograms: 90)
        let store = FoodImportWeightStore()
        let coordinator = makeCoordinator(.bodyWeight, weight: BodyWeightRepository(store: store))
        XCTAssertThrowsError(try coordinator.prepare(data: package(weights: [original, conflict])))
        XCTAssertEqual(store.saves, 0)
    }

    func testChangedCollectionIncludingSameIDContentInvalidatesMealReview() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let coordinator = makeCoordinator(.meals, nutrition: NutritionRepository(store: store))
        let review = try coordinator.prepare(data: package(meals: [meal()]))
        store.values = [meal(id: original.id, title: "Edited while reviewing")]
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id)) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .storeChanged)
        }
        XCTAssertEqual(store.saves, 0)
        XCTAssertNil(coordinator.review)
    }

    func testChangedWeightCollectionAfterReviewDoesNotOverwrite() throws {
        let store = FoodImportWeightStore()
        let coordinator = makeCoordinator(.bodyWeight, weight: BodyWeightRepository(store: store))
        let review = try coordinator.prepare(data: package(weights: [reading()]))
        let other = reading()
        store.values = [other]
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(store.values, [other])
        XCTAssertEqual(store.saves, 0)
    }

    func testGateIsCheckedAgainOnConfirmAndReconciliation() throws {
        let store = FoodImportWeightStore()
        var allowed = true
        let coordinator = makeCoordinator(.bodyWeight, weight: BodyWeightRepository(store: store), gate: { allowed })
        let review = try coordinator.prepare(data: package(weights: [reading()]))
        allowed = false
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(store.saves, 0)
        allowed = true
        store.mode = .landThenThrow
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        allowed = false
        XCTAssertThrowsError(try coordinator.reconcile(reviewID: review.id))
        XCTAssertEqual(store.saves, 1)
    }

    func testDiscardedOrFailedReplacementReviewCannotConfirmOldID() throws {
        let store = FoodImportNutritionStore()
        let coordinator = makeCoordinator(.meals, nutrition: NutritionRepository(store: store))
        let review = try coordinator.prepare(data: package(meals: [meal()]))
        coordinator.discardReview()
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        let replacement = try coordinator.prepare(data: package(meals: [meal()]))
        XCTAssertThrowsError(try coordinator.prepare(data: Data("{}".utf8)))
        XCTAssertThrowsError(try coordinator.confirm(reviewID: replacement.id))
        XCTAssertEqual(store.saves, 0)
    }

    func testMealWriteLandsReadbackFailsThenReadOnlyReconciliationConfirmsWithoutHealthCallback() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        let coordinator = makeCoordinator(.meals, nutrition: repository)
        let imported = meal()
        let review = try coordinator.prepare(data: package(meals: [imported]))
        store.mode = .landThenReadFails
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertTrue(coordinator.needsReconciliation)
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(repository.availability, .unavailable)
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertThrowsError(try coordinator.prepare(data: package(meals: [imported])))
        XCTAssertEqual(store.saves, 1)
        store.readsFail = false
        XCTAssertNotNil(try coordinator.reconcile(reviewID: review.id))
        XCTAssertEqual(repository.entries.count, 2)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(callbacks, 0)
    }

    func testWeightSaveLandsThenThrowsReconcilesExactWholeCollectionWithoutAnotherSave() throws {
        let store = FoodImportWeightStore()
        let repository = BodyWeightRepository(store: store)
        let coordinator = makeCoordinator(.bodyWeight, weight: repository)
        let review = try coordinator.prepare(data: package(weights: [reading()]))
        store.mode = .landThenThrow
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(repository.entries, [])
        XCTAssertFalse(repository.isAvailable)
        XCTAssertNotNil(try coordinator.reconcile(reviewID: review.id))
        XCTAssertEqual(repository.entries, review.weights)
        XCTAssertEqual(store.saves, 1)
    }

    func testWeightSaveLandsReadbackFailsPreservesLastReadableStateUntilRecovery() throws {
        let original = reading()
        let store = FoodImportWeightStore([original])
        let repository = BodyWeightRepository(store: store)
        let coordinator = makeCoordinator(.bodyWeight, weight: repository)
        let review = try coordinator.prepare(data: package(weights: [reading()]))
        store.mode = .landThenReadFails
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertEqual(repository.entries, [original])
        XCTAssertThrowsError(try coordinator.reconcile(reviewID: review.id))
        store.readsFail = false
        XCTAssertNotNil(try coordinator.reconcile(reviewID: review.id))
        XCTAssertEqual(store.saves, 1)
    }

    func testRejectedWriteReconciliationIsReadOnlyAndRequiresFreshReview() throws {
        let store = FoodImportNutritionStore()
        let coordinator = makeCoordinator(.meals, nutrition: NutritionRepository(store: store))
        let review = try coordinator.prepare(data: package(meals: [meal()]))
        store.mode = .reject
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        XCTAssertNil(try coordinator.reconcile(reviewID: review.id))
        XCTAssertEqual(store.saves, 1)
        XCTAssertNil(coordinator.review)
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
    }

    func testUnrelatedRecordAfterAmbiguousWritePreventsFalseConfirmation() throws {
        let store = FoodImportWeightStore()
        let coordinator = makeCoordinator(.bodyWeight, weight: BodyWeightRepository(store: store))
        let review = try coordinator.prepare(data: package(weights: [reading()]))
        store.mode = .landThenThrow
        XCTAssertThrowsError(try coordinator.confirm(reviewID: review.id))
        store.values.append(reading())
        XCTAssertThrowsError(try coordinator.reconcile(reviewID: review.id)) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .storeChanged)
        }
        XCTAssertEqual(store.saves, 1)
        coordinator.discardReview()
        let fresh = try coordinator.prepare(data: package(weights: review.weights))
        XCTAssertEqual(fresh.appendedCount, 0)
    }

    func testMalformedStoreBlocksAndPreservesLastReadableMeals() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let repository = NutritionRepository(store: store)
        store.values = [original, original]
        XCTAssertThrowsError(try makeCoordinator(.meals, nutrition: repository).prepare(data: package(meals: [meal()])))
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(repository.availability, .unavailable)
        XCTAssertEqual(store.saves, 0)
    }

    func testWrongTypeAndMalformedUserDefaultsAreNeverTreatedAsEmptyAvailableStore() throws {
        let suite = "FoodBodyWeightImportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "synthetic-meals")
        for malformed in ["wrong type" as Any, Data("{bad json}".utf8)] {
            defaults.set(malformed, forKey: "synthetic-meals")
            XCTAssertFalse(store.isAvailable)
            XCTAssertThrowsError(try store.loadVerified())
            let repository = NutritionRepository(store: store)
            XCTAssertEqual(repository.availability, .unavailable)
            XCTAssertThrowsError(try makeCoordinator(.meals, nutrition: repository).prepare(data: package(meals: [meal()])))
            store.save([meal()])
            XCTAssertEqual(defaults.object(forKey: "synthetic-meals") as? NSObject, malformed as? NSObject)
        }
    }

    func testRepositoryImportAPIsRejectRemovalAndReplacementEvenWithFreshBaseline() throws {
        let originalMeal = meal()
        let mealStore = FoodImportNutritionStore([originalMeal])
        let nutrition = NutritionRepository(store: mealStore)
        XCTAssertThrowsError(try nutrition.importReviewed([], replacing: [originalMeal]))
        XCTAssertThrowsError(try nutrition.importReviewed([meal(id: originalMeal.id, title: "Changed")], replacing: [originalMeal]))
        XCTAssertEqual(mealStore.values, [originalMeal])
        XCTAssertEqual(mealStore.saves, 0)
        let originalWeight = reading()
        let weightStore = FoodImportWeightStore([originalWeight])
        let weight = BodyWeightRepository(store: weightStore)
        XCTAssertThrowsError(try weight.importReviewed([], replacing: [originalWeight]))
        XCTAssertThrowsError(try weight.importReviewed([reading(id: originalWeight.id, kilograms: 90)], replacing: [originalWeight]))
        XCTAssertEqual(weightStore.values, [originalWeight])
        XCTAssertEqual(weightStore.saves, 0)
    }

    func testUnsupportedPayloadIsSkippedWithoutInspectingItsKilogramsFields() throws {
        let valid = try package(weights: [reading()])
        let source = try FoodBodyWeightImportDecoder.decode(changingRoot(valid, key: "goalsAndPreferences",
            value: ["kilograms": "unrelated unsupported value"]), category: .bodyWeight)
        XCTAssertEqual(source.weights.count, 1)
        XCTAssertTrue(source.skippedCategories.contains("Goals and preferences"))
    }

    func testEscapedWeightKeyAndScientificScalarPreserveExactNumericValue() throws {
        let raw = String(decoding: rawWeightPackage(id: UUID(), kilograms: "8.2123456789012345678901234567890123456e1"), as: UTF8.self)
            .replacingOccurrences(of: "\"kilograms\"", with: "\"kilo\\u0067rams\"")
        let source = try FoodBodyWeightImportDecoder.decode(Data(raw.utf8), category: .bodyWeight)
        XCTAssertEqual(source.weights.first?.kilograms, Decimal(string: "82.123456789012345678901234567890123456"))
    }

    func testReadFailureBetweenAvailabilityAndNutritionLoadCannotBecomeEmptyBaseline() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let repository = NutritionRepository(store: store)
        store.readsFail = true
        XCTAssertThrowsError(try makeCoordinator(.meals, nutrition: repository).prepare(data: package(meals: [meal()])))
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(store.saves, 0)
    }

    func testInvalidWeightStoreRetainsLastReadableStateAndDoesNotSave() throws {
        let original = reading()
        let store = FoodImportWeightStore([original])
        let repository = BodyWeightRepository(store: store)
        store.values = [reading(kilograms: NSDecimalNumber.notANumber.decimalValue)]
        XCTAssertThrowsError(try makeCoordinator(.bodyWeight, weight: repository).prepare(data: package(weights: [reading()])))
        XCTAssertEqual(repository.entries, [original])
        XCTAssertFalse(repository.isAvailable)
        XCTAssertEqual(store.saves, 0)
    }

    func testStaleOrdinaryMealRepositoryCannotOverwriteImportedOrOtherFreshRecords() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let repository = NutritionRepository(store: store)
        let other = meal(title: "Fresh imported record")
        store.values.append(other)
        var draft = NutritionEntryDraft()
        draft.title = "New meal"; draft.calories = "100"
        XCTAssertThrowsError(try repository.add(draft))
        XCTAssertEqual(Set(store.values.map(\.id)), [original.id, other.id])
        XCTAssertEqual(store.saves, 0)
    }

    func testOversizedOrdinaryFoodNameRejectsAddAndEditBeforeSavingAndKeepsHealthyStateUsable() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        var draft = NutritionEntryDraft()
        draft.title = String(repeating: "🍎", count: 1_025)
        draft.calories = "100"
        XCTAssertLessThan(draft.title.count, 4_096, "The limit concerns stored UTF-8 bytes, not character count")
        XCTAssertThrowsError(try repository.add(draft)) {
            XCTAssertEqual($0 as? NutritionEntryValidationError, .titleTooLong)
            XCTAssertEqual($0.localizedDescription, "Use a shorter food name before saving.")
        }
        var oversizedCorrection = NutritionEntryDraft(entry: original)
        oversizedCorrection.title = draft.title; oversizedCorrection.calories = draft.calories
        XCTAssertThrowsError(try repository.update(id: original.id, with: oversizedCorrection)) {
            XCTAssertEqual($0 as? NutritionEntryValidationError, .titleTooLong)
        }
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.values, [original])
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(repository.availability, .available)
        XCTAssertNil(repository.persistenceErrorMessage)
        XCTAssertEqual(callbacks, 0)
        draft.title = String(repeating: "🍎", count: 1_024)
        let added = try repository.add(draft)
        XCTAssertEqual(added.title, draft.title, "Boundary values are preserved without truncation")
        XCTAssertEqual(store.values.first(where: { $0.id == original.id }), original)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(repository.availability, .available)
    }

    func testInvalidOrdinaryMealCandidateDateCannotWriteOrPoisonHealthyStore() throws {
        let original = meal()
        let store = FoodImportNutritionStore([original])
        let repository = NutritionRepository(store: store)
        var draft = NutritionEntryDraft()
        draft.title = "Valid food name"; draft.calories = "100"
        XCTAssertThrowsError(try repository.add(draft, at: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.values, [original])
        XCTAssertEqual(repository.entries, [original])
        XCTAssertEqual(repository.availability, .available)
        XCTAssertNil(repository.persistenceErrorMessage)
        _ = try repository.add(draft)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(repository.availability, .available)
    }

    func testOrdinaryAddBeyondCollectionBoundRefusesWriteAndAllowsExistingRecordEdit() throws {
        let existing = (0..<FoodBodyWeightImportDecoder.maximumRecords).map { index in
            NutritionEntry(id: UUID(), title: "Synthetic existing food", calories: 1,
                proteinGrams: nil, carbohydrateGrams: nil, fatGrams: nil,
                loggedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        let store = FoodImportNutritionStore(existing)
        let repository = NutritionRepository(store: store)
        let baseline = repository.entries
        var draft = NutritionEntryDraft()
        draft.title = "Synthetic new food"; draft.calories = "100"
        XCTAssertThrowsError(try repository.add(draft))
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.values, existing)
        XCTAssertEqual(repository.entries, baseline)
        XCTAssertEqual(repository.availability, .available)
        XCTAssertNil(repository.persistenceErrorMessage)
        let original = try XCTUnwrap(baseline.first)
        var correction = NutritionEntryDraft(entry: original)
        correction.title = draft.title; correction.calories = draft.calories
        let edited = try repository.update(id: original.id, with: correction)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.loggedAt, original.loggedAt)
        XCTAssertEqual(store.values.count, existing.count)
        XCTAssertEqual(Set(store.values.map(\.id)), Set(existing.map(\.id)))
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(repository.availability, .available)
    }

    func testProductionBodyWeightStoreImportRoundTripsHighPrecisionDecimal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodWeightImport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBodyWeightStore(rootURL: root)
        let repository = BodyWeightRepository(store: store)
        let coordinator = makeCoordinator(.bodyWeight, weight: repository)
        let exact = "82.123456789012345678901234567890123456"
        let review = try coordinator.prepare(data: rawWeightPackage(id: UUID(), kilograms: exact))
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(try store.load(), review.weights)
        XCTAssertEqual(BodyWeightRepository(store: store).entries.first?.kilograms, Decimal(string: exact))
    }

    func testProductionUserDefaultsImportRoundTripsRawMealWithoutCallback() throws {
        let suite = "FoodWeightImport-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNutritionStore(defaults: defaults, key: "synthetic-meals")
        var callbacks = 0
        let repository = NutritionRepository(store: store, onConfirmedAddition: { _ in callbacks += 1 })
        let coordinator = makeCoordinator(.meals, nutrition: repository)
        let imported = meal(protein: nil, carbohydrate: 123.1234567890123)
        let review = try coordinator.prepare(data: package(meals: [imported]))
        _ = try coordinator.confirm(reviewID: review.id)
        XCTAssertEqual(try store.loadVerified(), [imported])
        XCTAssertEqual(NutritionRepository(store: store).entries, [imported])
        XCTAssertEqual(callbacks, 0)
    }

    func testHostileJSONDuplicateEscapedKeysDepthUnknownKeysAndSizeRejected() throws {
        let valid = String(decoding: try package(meals: [meal()]), as: UTF8.self)
        let cases = [
            "{\"schemaVersion\":3,\"schema\\u0056ersion\":3}",
            String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34),
            valid.replacingOccurrences(of: "\"calories\":", with: "\"newFact\":1,\"calories\":"),
            valid.replacingOccurrences(of: "\"selection\":{", with: "\"selection\":{\"newSelection\":true,")
        ]
        for hostile in cases {
            XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(Data(hostile.utf8), category: .meals))
        }
        XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(
            Data(repeating: 32, count: FoodBodyWeightImportDecoder.maximumFileBytes + 1), category: .meals)) {
            XCTAssertEqual($0 as? FoodBodyWeightImportError, .oversizedFile)
        }
    }

    func testInvalidMealScalarIDDateMacroBooleanAndArrayShapesReject() throws {
        let valid = try package(meals: [meal()])
        let mutations: [(String, Any)] = [
            ("id", "invalid-id"), ("calories", true), ("calories", -1), ("calories", 1.5),
            ("title", " "), ("loggedAt", "2026-10-03"), ("loggedAt", 1e101),
            ("fatGrams", -1), ("proteinGrams", true), ("carbohydrateGrams", 1001)
        ]
        for (key, value) in mutations {
            XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(
                changingRow(valid, array: "meals", key: key, value: value), category: .meals))
        }
        let invalidArray = try changingRoot(valid, key: "meals", value: ["not a record"])
        XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(invalidArray, category: .meals))
    }

    func testWeightPrecisionOverflowStringBooleanAndNonfiniteCannotBeSilentlyNormalized() throws {
        for value in ["82.123456789012345678901234567890123456789", "\"82.5\"", "true", "null", "1e999", "0.49", "1000.1"] {
            XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(
                rawWeightPackage(id: UUID(), kilograms: value), category: .bodyWeight))
        }
    }

    func testSelectionSchemaUnitAndProvenanceAreRequiredAndOtherCategoriesAreSkipped() throws {
        let valid = try package(meals: [meal()], weights: [reading()])
        let source = try FoodBodyWeightImportDecoder.decode(valid, category: .meals)
        XCTAssertTrue(source.skippedCategories.contains("Water daily snapshot"))
        XCTAssertTrue(source.skippedCategories.contains("Body-weight readings"))
        XCTAssertTrue(source.weights.isEmpty)
        let weightSource = try FoodBodyWeightImportDecoder.decode(valid, category: .bodyWeight)
        XCTAssertTrue(weightSource.skippedCategories.contains("Food records"))
        for (key, value) in [("schemaVersion", 99 as Any), ("bodyWeightStoredUnit", "lb"),
                             ("bodyWeightProvenance", "Apple Health")] {
            XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(
                changingRoot(valid, key: key, value: value), category: .bodyWeight))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var selection = try XCTUnwrap(object["selection"] as? [String: Any])
        selection["mealsAndWater"] = false; object["selection"] = selection
        XCTAssertThrowsError(try FoodBodyWeightImportDecoder.decode(JSONSerialization.data(withJSONObject: object), category: .meals))
    }

    private func meal(id: UUID = UUID(), title: String = "Synthetic meal", protein: Double? = nil,
                      carbohydrate: Double? = nil) -> NutritionEntry {
        NutritionEntry(id: id, title: title, calories: 321, proteinGrams: protein,
            carbohydrateGrams: carbohydrate, fatGrams: nil,
            loggedAt: Date(timeIntervalSinceReferenceDate: 812345678.1234567))
    }
    private func reading(id: UUID = UUID(), kilograms: Decimal = 82.5) -> BodyWeightEntry {
        BodyWeightEntry(id: id, recordedAt: Date(timeIntervalSinceReferenceDate: 812345678.1234567), kilograms: kilograms)
    }
    private func makeCoordinator(_ category: FoodBodyWeightImportCategory,
                                 nutrition: NutritionRepository? = nil, weight: BodyWeightRepository? = nil,
                                 gate: @escaping @MainActor () throws -> Bool = { true }) -> FoodBodyWeightImportCoordinator {
        FoodBodyWeightImportCoordinator(category: category,
            nutrition: nutrition ?? NutritionRepository(store: FoodImportNutritionStore()),
            bodyWeight: weight ?? BodyWeightRepository(store: FoodImportWeightStore()), canImport: gate)
    }
    private func package(meals: [NutritionEntry] = [], weights: [BodyWeightEntry] = []) throws -> Data {
        try JSONEncoder().encode(LocalDataExportPackage(exportedAt: Date(timeIntervalSinceReferenceDate: 812345700),
            completedWorkouts: [], bodyWeightReadings: weights,
            selection: .init(workouts: false, mealsAndWater: true, bodyWeight: true,
                outdoorActivities: false, routes: false, goalsAndPreferences: false),
            meals: meals, waterSnapshot: nil, outdoorActivities: nil, goalsAndPreferences: nil))
    }
    private func rawWeightPackage(id: UUID, kilograms: String, date: String = "812345678") -> Data {
        Data("""
        {"schemaVersion":3,"exportedAt":812345700,"selection":{"workouts":false,"mealsAndWater":false,"bodyWeight":true},"bodyWeightProvenance":"app-owned local body weight records; original input source unknown","bodyWeightStoredUnit":"kg","bodyWeightReadings":[{"id":"\(id.uuidString)","recordedAt":\(date),"kilograms":\(kilograms)}]}
        """.utf8)
    }
    private func changingRoot(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func changingRow(_ data: Data, array: String, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(object[array] as? [[String: Any]])
        rows[0][key] = value; object[array] = rows
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private final class FoodImportNutritionStore: NutritionPersisting {
    enum Mode { case normal, reject, landThenReadFails }
    var values: [NutritionEntry]
    var saves = 0
    var readsFail = false
    var mode = Mode.normal
    var isAvailable: Bool { !readsFail }
    init(_ values: [NutritionEntry] = []) { self.values = values }
    func load() -> [NutritionEntry] { values }
    func loadVerified() throws -> [NutritionEntry] {
        if readsFail { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    func save(_ entries: [NutritionEntry]) {
        saves += 1
        if mode == .reject { return }
        values = entries
        if mode == .landThenReadFails { readsFail = true }
    }
}

private final class FoodImportWeightStore: BodyWeightPersisting {
    enum Mode { case normal, reject, landThenThrow, landThenReadFails }
    var values: [BodyWeightEntry]
    var saves = 0
    var readsFail = false
    var mode = Mode.normal
    init(_ values: [BodyWeightEntry] = []) { self.values = values }
    func load() throws -> [BodyWeightEntry] {
        if readsFail { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    func save(_ entries: [BodyWeightEntry]) throws {
        saves += 1
        if mode == .reject { throw CocoaError(.fileWriteUnknown) }
        values = entries
        if mode == .landThenThrow { throw CocoaError(.fileWriteUnknown) }
        if mode == .landThenReadFails { readsFail = true }
    }
}
