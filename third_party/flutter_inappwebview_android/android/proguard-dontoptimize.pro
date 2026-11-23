# AGP 9 rejects getDefaultProguardFile('proguard-android.txt') because it carries
# -dontoptimize. build.gradle now uses proguard-android-optimize.txt and adds this
# file to keep the module's own minify behaviour unchanged. Deliberately NOT a
# consumerProguardFiles entry: -dontoptimize there would switch R8 optimization
# off for the whole app. See PATCHES.md.
-dontoptimize
