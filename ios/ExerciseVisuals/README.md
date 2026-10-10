# Slick Exercise Visuals

Exercise artwork is referenced by explicit asset names in `ExerciseLibrary`. Keep those names stable so workout data and UI composition never depend on filename guessing.

For each exercise, add up to three image sets beneath `Assets.xcassets/ExerciseVisuals/<ExerciseName>/`:

- `<ExerciseName>Hero.imageset` — featured Today and onboarding compositions.
- `<ExerciseName>Card.imageset` — workout and exercise-selection surfaces.
- `<ExerciseName>Thumbnail.imageset` — compact next-up and list previews.

Then assign those exact asset names to `heroImageName`, `cardImageName`, and `thumbnailImageName` in `ExerciseLibrary.swift`. Missing sizes deliberately fall back to the closest available tier. If no artwork exists, the UI presents the shared category-aware production placeholder.

## Visual continuity

- Keep anatomy, athlete identity, camera angle, lighting, and crop consistent across all three tiers.
- Isolate the subject against a near-black environment with enough negative space for interface text.
- Reserve aqua for visual identity and environmental light; reserve acid-lime for performance/action emphasis.
- Avoid embedded text, logos, generic stock-photo lighting, and bright decorative backgrounds.
- Check that the subject remains legible when cropped with SwiftUI's `scaledToFill` behavior.

`BenchPressHero` is the current reference asset. It remains at the catalog root for backward compatibility and supplies all three levels for Barbell Bench Press until dedicated card and thumbnail crops are delivered.
