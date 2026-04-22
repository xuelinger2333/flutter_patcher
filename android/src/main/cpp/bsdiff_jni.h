#ifndef FLUTTER_PATCHER_BSDIFF_JNI_H
#define FLUTTER_PATCHER_BSDIFF_JNI_H

#include <stdint.h>

/* JNI 返回码约定（与 Kotlin BsDiffBridge 一致） */
#define BSDIFF_OK                0
#define BSDIFF_ERR_NOT_BUILT    -1   /* 未集成 upstream bsdiff 源码 */
#define BSDIFF_ERR_IO           -2   /* 读/写文件失败 */
#define BSDIFF_ERR_FORMAT       -3   /* 差分文件格式错误（magic / header） */
#define BSDIFF_ERR_DECOMPRESS   -4   /* bzip2 解压失败 */
#define BSDIFF_ERR_OOM          -5   /* 内存分配失败 */

/*
 * 主入口：对 old_path 应用 patch_path（bsdiff 格式），输出到 new_path。
 * 实现位于 third_party/bsdiff/bspatch.c（需要用户自行 drop-in）。
 * 返回 BSDIFF_* 常量。
 */
int flutter_patcher_bspatch(const char *old_path,
                            const char *new_path,
                            const char *patch_path);

#endif /* FLUTTER_PATCHER_BSDIFF_JNI_H */
