/*
 * JNI 桥：Java_com_flutter_1patcher_flutter_1patcher_BsDiffBridge_nativeApplyPatch
 *
 * Kotlin 侧 `com.flutter_patcher.flutter_patcher.BsDiffBridge.nativeApplyPatch(
 *     oldPath: String, newPath: String, patchPath: String): Int`
 *
 * 注：JNI 方法名里的下划线要转义成 `_1`，因为包名/类名里的 `_` 本身已是字符。
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "bsdiff_jni.h"

#define TAG "FlutterPatcher/JNI"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)

/* 探针：real 实现 = 1，stub = 0。由 bspatch.c / bsdiff_stub.c 提供 flutter_patcher_is_real。 */
extern int flutter_patcher_is_real(void);

JNIEXPORT jint JNICALL
Java_com_flutter_1patcher_flutter_1patcher_BsDiffBridge_nativeProbe(
        JNIEnv *env, jclass clazz) {
    (void) env; (void) clazz;
    return (jint) flutter_patcher_is_real();
}

JNIEXPORT jint JNICALL
Java_com_flutter_1patcher_flutter_1patcher_BsDiffBridge_nativeApplyPatch(
        JNIEnv *env, jclass clazz,
        jstring j_old, jstring j_new, jstring j_patch) {

    const char *old_path   = (*env)->GetStringUTFChars(env, j_old,   NULL);
    const char *new_path   = (*env)->GetStringUTFChars(env, j_new,   NULL);
    const char *patch_path = (*env)->GetStringUTFChars(env, j_patch, NULL);

    int rc = BSDIFF_ERR_NOT_BUILT;
    if (old_path && new_path && patch_path) {
        LOGI("bspatch: old=%s new=%s patch=%s", old_path, new_path, patch_path);
        rc = flutter_patcher_bspatch(old_path, new_path, patch_path);
        if (rc != BSDIFF_OK) {
            LOGE("bspatch failed rc=%d", rc);
        }
    }

    if (old_path)   (*env)->ReleaseStringUTFChars(env, j_old,   old_path);
    if (new_path)   (*env)->ReleaseStringUTFChars(env, j_new,   new_path);
    if (patch_path) (*env)->ReleaseStringUTFChars(env, j_patch, patch_path);

    return (jint) rc;
}
