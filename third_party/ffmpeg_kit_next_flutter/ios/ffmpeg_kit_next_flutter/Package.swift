// swift-tools-version: 5.9
// Swift Package Manager manifest for the iOS implementation of
// ffmpeg_kit_next_flutter. Flutter selects this when Swift Package Manager is
// enabled; the sibling ffmpeg_kit_next_flutter.podspec remains the CocoaPods
// fallback. Both reference the same Sources/ and Frameworks/ trees.
import PackageDescription

let package = Package(
    name: "ffmpeg_kit_next_flutter",
    platforms: [
        .iOS("12.1")
    ],
    products: [
        .library(name: "ffmpeg-kit-next-flutter", targets: ["ffmpeg_kit_next_flutter"])
    ],
    targets: [
        // FFmpegKit native binaries, built locally with nix-ios.sh and copied
        // into Frameworks/ by copy_local_binaries.sh. Git-ignored on purpose.
        .binaryTarget(name: "ffmpegkit",     path: "Frameworks/ffmpegkit.xcframework"),
        .binaryTarget(name: "libavcodec",    path: "Frameworks/libavcodec.xcframework"),
        .binaryTarget(name: "libavdevice",   path: "Frameworks/libavdevice.xcframework"),
        .binaryTarget(name: "libavfilter",   path: "Frameworks/libavfilter.xcframework"),
        .binaryTarget(name: "libavformat",   path: "Frameworks/libavformat.xcframework"),
        .binaryTarget(name: "libavutil",     path: "Frameworks/libavutil.xcframework"),
        .binaryTarget(name: "libswresample", path: "Frameworks/libswresample.xcframework"),
        .binaryTarget(name: "libswscale",    path: "Frameworks/libswscale.xcframework"),
        .target(
            name: "ffmpeg_kit_next_flutter",
            dependencies: [
                "ffmpegkit", "libavcodec", "libavdevice", "libavfilter",
                "libavformat", "libavutil", "libswresample", "libswscale"
            ],
            cSettings: [
                .headerSearchPath("include")
            ]
        )
    ]
)
