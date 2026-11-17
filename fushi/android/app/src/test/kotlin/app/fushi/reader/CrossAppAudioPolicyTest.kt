package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 跨应用语音缓存通道的线程归属（BUG-4791）与授权页销毁结账（BUG-4792）。 */
class CrossAppAudioPolicyTest {
    @Test
    fun providerRpcMethodsRunOffMain() {
        for (m in listOf("status", "stop", "snapshot")) {
            assertTrue(CrossAppAudioPolicy.callsProviderOffMain(m), m)
        }
    }

    @Test
    fun localMethodsStayOnMain() {
        // start 读写只在主线程的 pendingStart 并起 Activity；encodeAac 自己投编码线程。
        for (m in listOf("isSupported", "start", "encodeAac", "someFutureMethod")) {
            assertFalse(CrossAppAudioPolicy.callsProviderOffMain(m), m)
        }
    }

    @Test
    fun nonConfigChangeDestroyReleasesPendingStart() {
        // 系统回收 / 划掉最近任务：isFinishing() 为假，也必须结账，否则之后每次开启都 busy。
        assertTrue(CrossAppAudioPolicy.releasesPendingStartOnDestroy(true, false))
    }

    @Test
    fun configChangeRecreateKeepsWaiting() {
        assertFalse(CrossAppAudioPolicy.releasesPendingStartOnDestroy(true, true))
    }

    @Test
    fun nothingOwedNothingReleased() {
        assertFalse(CrossAppAudioPolicy.releasesPendingStartOnDestroy(false, false))
        assertFalse(CrossAppAudioPolicy.releasesPendingStartOnDestroy(false, true))
    }
}
