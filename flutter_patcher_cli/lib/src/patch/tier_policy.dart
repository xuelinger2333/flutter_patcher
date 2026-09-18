/// Prefer host reuse. Whole must still pass its own compatibility checks.
String selectPatchTier({
  required bool leanChecked,
  required bool dependencyChanged,
  required bool resourceUpgrade,
}) =>
    leanChecked && !dependencyChanged && !resourceUpgrade ? 'lean' : 'whole';
