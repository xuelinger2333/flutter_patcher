/*
 * Real-build probe helper. Compiled automatically when `third_party/bsdiff`
 * contains at least one .c file (because CMakeLists.txt globs `third_party/*.c`
 * via the bsdiff subdir; this file lives at the root of third_party/ so the
 * probe is only included when upstream sources were added).
 *
 * Returns 1 → BsDiffBridge.isAvailable() == true.
 */
int flutter_patcher_is_real(void) {
    return 1;
}
