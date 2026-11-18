package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** 下载 Live Update 胶囊短文本：0..100 显示百分比，其它（不确定进度）不给。 */
class DownloadLiveUpdateTest {
    @Test
    fun determinateProgressShowsPercent() {
        assertEquals("0%", DownloadLiveUpdate.shortCriticalText(0))
        assertEquals("42%", DownloadLiveUpdate.shortCriticalText(42))
        assertEquals("100%", DownloadLiveUpdate.shortCriticalText(100))
    }

    @Test
    fun indeterminateProgressHasNoShortText() {
        assertNull(DownloadLiveUpdate.shortCriticalText(-1))
        assertNull(DownloadLiveUpdate.shortCriticalText(101))
    }
}
