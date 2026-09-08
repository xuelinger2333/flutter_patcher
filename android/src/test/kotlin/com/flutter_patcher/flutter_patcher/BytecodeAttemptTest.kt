package com.flutter_patcher.flutter_patcher

import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class BytecodeAttemptTest {
    @Test fun fallbackFrameAndDuplicateErrorsCannotSettleFailedAttempt() {
        val attempt = BytecodeAttempt("one")
        assertFalse(attempt.start(null))
        assertTrue(attempt.start("one"))
        assertFalse(attempt.start("one"))
        assertTrue(attempt.fail("one"))
        assertFalse(attempt.fail("one"))
        assertFalse(attempt.succeed("one"))
        assertFalse(attempt.succeed(null))
    }
    @Test fun firstFrameIsIdempotentButSubsequentDartErrorStillCountsOnce() {
        val attempt = BytecodeAttempt("one")
        assertFalse(attempt.succeed("one"))
        assertTrue(attempt.start("one"))
        assertTrue(attempt.succeed("one"))
        assertFalse(attempt.succeed("one"))
        assertFalse(attempt.fail("old"))
        assertTrue(attempt.fail("one"))
        assertFalse(attempt.fail("one"))
    }
}
