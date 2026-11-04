import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 10 控制中心控件（iOS 18 / macOS 26）
//
// iOS：控制中心、锁屏两侧键位、Action 按钮；macOS 26：控制中心与菜单栏。

@available(iOS 18.0, macOS 26.0, *)
struct FushiLookupControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.fushi.controls.lookup") {
      ControlWidgetButton(action: FushiOpenLinkIntent(url: FushiLinks.lookup)) {
        Label { Text(FushiGallery.lookupName) } icon: { Image(systemName: "magnifyingglass") }
      }
    }
    .displayName(FushiGallery.lookupName)
  }
}

@available(iOS 18.0, macOS 26.0, *)
struct FushiCameraLookupControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.fushi.controls.camera_lookup") {
      ControlWidgetButton(action: FushiOpenLinkIntent(url: FushiLinks.cameraLookup)) {
        Label { Text(FushiGallery.cameraLookupName) } icon: { Image(systemName: "camera.viewfinder") }
      }
    }
    .displayName(FushiGallery.cameraLookupName)
  }
}

@available(iOS 18.0, macOS 26.0, *)
struct FushiReviewControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.fushi.controls.review") {
      ControlWidgetButton(action: FushiOpenLinkIntent(url: FushiLinks.review)) {
        Label { Text(FushiGallery.reviewControlName) } icon: { Image(systemName: "rectangle.stack") }
      }
    }
    .displayName(FushiGallery.reviewControlName)
  }
}

@available(iOS 18.0, macOS 26.0, *)
struct FushiResumeListeningControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.fushi.controls.resume_audiobook") {
      ControlWidgetButton(action: resumeIntent) {
        Label { Text(FushiGallery.audiobookName) } icon: { Image(systemName: "headphones") }
      }
    }
    .displayName(FushiGallery.audiobookName)
  }

  #if os(iOS)
    private var resumeIntent: FushiResumeAudiobookIntent {
      FushiResumeAudiobookIntent(url: FushiLinks.resumeListening)
    }
  #else
    private var resumeIntent: FushiOpenLinkIntent {
      FushiOpenLinkIntent(url: FushiLinks.resumeListening)
    }
  #endif
}
