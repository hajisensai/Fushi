//
//  FushiContentRuleLists.swift
//  flutter_inappwebview (Fushi patch, BUG-4013)
//
//  Upstream 1.1.2 re-serialised `settings.contentBlockers` and called
//  `WKContentRuleListStore.compileContentRuleList` (fixed identifier
//  "ContentBlockingRules", no cache) for every WebView, and again on every
//  `setSettings`. With ~50k ad-block rules that is a full Swift dictionary
//  parse + WebKit compile per WebView, which exhausted the iOS virtual
//  address space.
//
//  This file makes the rule set a process-wide, content-addressed resource:
//  - Dart computes a stable identifier (`fushi-adblock-<sha256>`) and calls the
//    `fushi/content_rule_list` channel once per rule set: `activate` (memory
//    cache -> `lookUpContentRuleList` on the persistent store) and only on a
//    miss `compile` with the raw WebKit JSON bytes. Compiled lists persist in
//    `WKContentRuleListStore.default()` across launches.
//  - Each WebView only carries a one-entry *reference* in `contentBlockers`
//    (`url-filter` = "fushi-content-rule-list:<identifier>"); every WebView
//    shares the same `WKContentRuleList` instance, and a WebView whose
//    reference did not change is not touched on `setSettings`.
//  - After a rule set is activated, stale `fushi-adblock-*` lists and the
//    upstream "ContentBlockingRules" list are removed from the store.
//
//  The iOS copy (flutter_inappwebview_ios-1.1.2) is identical apart from the
//  Flutter module import and `registrar.messenger`.
//

import Foundation
import WebKit
import FlutterMacOS

@available(macOS 10.13, *)
public final class FushiContentRuleLists: NSObject {
    public static let METHOD_CHANNEL_NAME = "fushi/content_rule_list"
    /// Prefix of every identifier Fushi compiles into the store.
    public static let IDENTIFIER_PREFIX = "fushi-adblock-"
    /// `url-filter` prefix of the reference entry a WebView carries.
    public static let REFERENCE_PREFIX = "fushi-content-rule-list:"
    /// Identifier upstream compiled into the store on every WebView.
    static let LEGACY_IDENTIFIER = "ContentBlockingRules"

    public static let shared = FushiContentRuleLists()

    /// Main-thread only. Holds the active list (at most one entry).
    private var lists: [String: WKContentRuleList] = [:]

    /// The identifier referenced by [contentBlockers], or nil when they are
    /// ordinary inline rules (upstream behaviour) / empty.
    public static func referencedIdentifier(_ contentBlockers: [[String: [String: Any]]]) -> String? {
        guard contentBlockers.count == 1,
              let filter = contentBlockers[0]["trigger"]?["url-filter"] as? String,
              filter.hasPrefix(REFERENCE_PREFIX) else {
            return nil
        }
        let identifier = String(filter.dropFirst(REFERENCE_PREFIX.count))
        return identifier.hasPrefix(IDENTIFIER_PREFIX) ? identifier : nil
    }

    /// Memory cache first, then the persistent store. Completion runs on the
    /// main thread (synchronously on a memory hit).
    public func resolve(_ identifier: String, completion: @escaping (WKContentRuleList?) -> Void) {
        if let list = lists[identifier] {
            completion(list)
            return
        }
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            DispatchQueue.main.async {
                if let list = list {
                    self?.lists = [identifier: list]
                }
                completion(list)
            }
        }
    }

    func activate(_ identifier: String, result: @escaping FlutterResult) {
        resolve(identifier) { [weak self] list in
            if list != nil {
                self?.purgeStore(keeping: identifier)
            }
            result(list != nil)
        }
    }

    func compile(_ identifier: String, json: Data, result: @escaping FlutterResult) {
        // Building a String from the multi-MB JSON stays off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let encoded = String(data: json, encoding: .utf8) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "invalid_json", message: "content rule list is not UTF-8", details: nil))
                }
                return
            }
            DispatchQueue.main.async {
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encoded) { [weak self] list, error in
                        DispatchQueue.main.async {
                            guard let list = list else {
                                result(FlutterError(code: "compile_failed", message: error?.localizedDescription, details: nil))
                                return
                            }
                            self?.lists = [identifier: list]
                            self?.purgeStore(keeping: identifier)
                            result(true)
                        }
                }
            }
        }
    }

    /// Removes every other Fushi list (and upstream's fixed-identifier list)
    /// so the store does not grow with each rule-set update.
    private func purgeStore(keeping identifier: String) {
        let store = WKContentRuleListStore.default()
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for stale in identifiers ?? [] where stale != identifier &&
                (stale.hasPrefix(FushiContentRuleLists.IDENTIFIER_PREFIX) || stale == FushiContentRuleLists.LEGACY_IDENTIFIER) {
                store.removeContentRuleList(forIdentifier: stale) { _ in }
            }
        }
    }
}

/// Per-engine channel; the compiled lists themselves are process-wide
/// ([FushiContentRuleLists.shared]).
@available(macOS 10.13, *)
public final class FushiContentRuleListChannel: NSObject {
    private var channel: FlutterMethodChannel?

    public init(messenger: FlutterBinaryMessenger) {
        super.init()
        let channel = FlutterMethodChannel(name: FushiContentRuleLists.METHOD_CHANNEL_NAME, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            let arguments = call.arguments as? [String: Any]
            guard let identifier = arguments?["identifier"] as? String,
                  identifier.hasPrefix(FushiContentRuleLists.IDENTIFIER_PREFIX) else {
                result(FlutterError(code: "bad_args", message: "missing fushi-adblock-* identifier", details: nil))
                return
            }
            switch call.method {
            case "activate":
                FushiContentRuleLists.shared.activate(identifier, result: result)
            case "compile":
                guard let json = arguments?["json"] as? FlutterStandardTypedData else {
                    result(FlutterError(code: "bad_args", message: "missing json bytes", details: nil))
                    return
                }
                FushiContentRuleLists.shared.compile(identifier, json: json.data, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        self.channel = channel
    }

    public func dispose() {
        channel?.setMethodCallHandler(nil)
        channel = nil
    }
}

extension InAppWebView {
    /// Applies the referenced shared list to this WebView. Returns false when
    /// [contentBlockers] is not a Fushi reference (caller keeps upstream
    /// behaviour). [completion] runs once the list is attached (or could not
    /// be resolved); synchronously when it is already in memory.
    @available(macOS 10.13, *)
    func applyFushiContentRuleList(_ contentBlockers: [[String: [String: Any]]], completion: @escaping () -> Void) -> Bool {
        guard let identifier = FushiContentRuleLists.referencedIdentifier(contentBlockers) else {
            fushiContentRuleListIdentifier = nil
            return false
        }
        if fushiContentRuleListIdentifier == identifier {
            completion()
            return true
        }
        FushiContentRuleLists.shared.resolve(identifier) { [weak self] list in
            guard let self = self else { return }
            self.configuration.userContentController.removeAllContentRuleLists()
            if let list = list {
                self.configuration.userContentController.add(list)
                self.fushiContentRuleListIdentifier = identifier
            } else {
                // Dart activates / compiles before creating the WebView; a miss
                // here means the store was wiped underneath us.
                self.fushiContentRuleListIdentifier = nil
                print("Fushi content rule list \(identifier) is not prepared")
            }
            completion()
        }
        return true
    }
}
