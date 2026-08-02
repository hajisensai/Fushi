package eu.kanade.tachiyomi

class BuildConfig {
    companion object {
        const val VERSION_NAME = mextensionserver.BuildConfig.NAME
        val VERSION_CODE =
            mextensionserver.BuildConfig.REVISION
                .trimStart('r')
                .toInt()
    }
}
