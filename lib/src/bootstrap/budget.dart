/// Cold-start bootstrap wall time before patched main, not am-start delta.
int bootstrapBudgetUs(String tier) {
  switch (tier) {
    case 'lean':
      return 85000;
    case 'whole':
      return 250000;
    default:
      throw ArgumentError.value(tier, 'tier');
  }
}
