import Foundation

enum MockWorkoutFactory {
    static func upperBodyA() -> WorkoutSession {
        WorkoutSession(
            title: "Upper Body A",
            programmeID: .upperBodyA,
            exercises: [
                WorkoutExercise(
                    plan: ExercisePlan(
                        exerciseID: ExerciseIDs.barbellBenchPress,
                        name: "Barbell Bench Press",
                        targetLoad: Load(80),
                        targetReps: RepRange(6, 8),
                        plannedSetCount: 3,
                        restSeconds: 150,
                        previousPerformance: [
                            PreviousSetPerformance(load: Load(77.5), reps: 8),
                            PreviousSetPerformance(load: Load(77.5), reps: 8),
                            PreviousSetPerformance(load: Load(77.5), reps: 7)
                        ]
                    )
                ),
                WorkoutExercise(
                    plan: ExercisePlan(
                        exerciseID: ExerciseIDs.chestSupportedRow,
                        name: "Chest-Supported Row",
                        targetLoad: Load(65),
                        targetReps: RepRange(8, 10),
                        plannedSetCount: 3,
                        restSeconds: 120,
                        previousPerformance: [
                            PreviousSetPerformance(load: Load(62.5), reps: 10),
                            PreviousSetPerformance(load: Load(62.5), reps: 9),
                            PreviousSetPerformance(load: Load(62.5), reps: 9)
                        ]
                    )
                ),
                WorkoutExercise(
                    plan: ExercisePlan(
                        exerciseID: ExerciseIDs.seatedDumbbellShoulderPress,
                        name: "Seated Dumbbell Shoulder Press",
                        targetLoad: Load(24),
                        targetReps: RepRange(8, 10),
                        plannedSetCount: 3,
                        restSeconds: 120,
                        previousPerformance: [
                            PreviousSetPerformance(load: Load(22), reps: 10),
                            PreviousSetPerformance(load: Load(22), reps: 9),
                            PreviousSetPerformance(load: Load(22), reps: 8)
                        ]
                    )
                )
            ]
        )
    }

    static func lowerBodyA() -> WorkoutSession {
        WorkoutSession(
            title: "Lower Body A",
            exercises: [
                exercise(ExerciseIDs.backSquat, "Back Squat", load: 100, reps: 5 ... 8, sets: 3, rest: 180),
                exercise(ExerciseIDs.romanianDeadlift, "Romanian Deadlift", load: 90, reps: 6 ... 10, sets: 3, rest: 150),
                exercise(ExerciseIDs.seatedLegCurl, "Seated Leg Curl", load: 55, reps: 8 ... 12, sets: 3, rest: 90),
                exercise(ExerciseIDs.standingCalfRaise, "Standing Calf Raise", load: 70, reps: 10 ... 15, sets: 3, rest: 75)
            ]
        )
    }

    static func fullBodyA() -> WorkoutSession {
        WorkoutSession(
            title: "Full Body A",
            exercises: [
                exercise(ExerciseIDs.dumbbellBenchPress, "Dumbbell Bench Press", load: 28, reps: 8 ... 10, sets: 3, rest: 120),
                exercise(ExerciseIDs.latPulldown, "Lat Pulldown", load: 60, reps: 8 ... 10, sets: 3, rest: 120),
                exercise(ExerciseIDs.legPress, "Leg Press", load: 140, reps: 10 ... 12, sets: 3, rest: 150),
                exercise(ExerciseIDs.cableCrunch, "Cable Crunch", load: 40, reps: 10 ... 15, sets: 2, rest: 75)
            ]
        )
    }

    private static func exercise(
        _ exerciseID: ExerciseID,
        _ name: String,
        load: Double,
        reps: ClosedRange<Int>,
        sets: Int,
        rest: TimeInterval
    ) -> WorkoutExercise {
        WorkoutExercise(
            plan: ExercisePlan(
                exerciseID: exerciseID,
                name: name,
                targetLoad: Load(load),
                targetReps: RepRange(reps.lowerBound, reps.upperBound),
                plannedSetCount: sets,
                restSeconds: rest,
                previousPerformance: []
            )
        )
    }
}
