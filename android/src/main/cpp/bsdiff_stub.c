/*
 * Stub implementation used when upstream bsdiff + bzip2 sources are NOT present
 * under third_party/. Always returns BSDIFF_ERR_NOT_BUILT. Kotlin side will
 * treat this as "bsdiff module disabled" and reject mode=bsdiff patches.
 *
 * To enable real diff patching:
 *   1. Copy `bspatch.c` from Colin Percival's bsdiff-4.3 into
 *      android/src/main/cpp/third_party/bsdiff/
 *   2. Copy bzip2-1.0.x `*.c` + `*.h` into
 *      android/src/main/cpp/third_party/bzip2/
 *   3. In bspatch.c rename the `main(...)` function to
 *      `flutter_patcher_bspatch(const char *old_path, const char *new_path,
 *                               const char *patch_path)` matching the
 *      prototype in bsdiff_jni.h.
 *   4. `flutter clean && flutter build apk`
 */
#include "bsdiff_jni.h"

int flutter_patcher_bspatch(const char *old_path,
                            const char *new_path,
                            const char *patch_path) {
    (void) old_path; (void) new_path; (void) patch_path;
    return BSDIFF_ERR_NOT_BUILT;
}

int flutter_patcher_is_real(void) {
    return 0; /* stub */
}
