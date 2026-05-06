package com.flutter_patcher.flutter_patcher

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PatchManagerTest {
    @Test
    fun validatePatchArgsAcceptsValidFullPatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetMd5 = "",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertNull(result)
    }

    @Test
    fun validatePatchArgsRejectsInvalidMd5BeforeDownload() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "bad-md5",
            mode = "full",
            targetMd5 = "",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRejectsTargetVersionCodeMismatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetMd5 = "",
            targetVersionCode = 101,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRequiresTargetMd5ForBsdiff() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/app.patch",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "bsdiff",
            targetMd5 = "",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }
}
