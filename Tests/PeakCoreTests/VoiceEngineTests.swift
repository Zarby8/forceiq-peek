import AppKit
import Foundation
import XCTest
@testable import PeakCore

/// Voice: the Apple Speech fallback decision (on-device only), the toggle state machine, and the live caption in the notch row.
final class VoiceEngineTests: XCTestCase {
    // ── fallback ──
    func testFallbackUsesAppleSpeechOnlyWhenItCanRunOnDevice() {
        XCTAssertEqual(VoiceFallback.decide(recognizerExists: true, onDeviceSupported: true, authorized: nil), .useAppleSpeech, "not asked yet: Peek asks at the first press")
        XCTAssertEqual(VoiceFallback.decide(recognizerExists: true, onDeviceSupported: true, authorized: true), .useAppleSpeech)
        XCTAssertEqual(VoiceFallback.decide(recognizerExists: true, onDeviceSupported: false, authorized: true), .unavailable(VoiceFallback.noOnDevice),
                       "never a cloud recognizer: audio must not leave the Mac")
        XCTAssertEqual(VoiceFallback.decide(recognizerExists: false, onDeviceSupported: false, authorized: nil), .unavailable(VoiceFallback.noOnDevice))
        XCTAssertEqual(VoiceFallback.decide(recognizerExists: true, onDeviceSupported: true, authorized: false), .unavailable(VoiceFallback.speechDenied))
    }

    func testFallbackWordingIsPlainAndNamesTheCause() {
        XCTAssertTrue(VoiceFallback.notice.contains("Apple Speech") && VoiceFallback.notice.contains("didn't load"))
        XCTAssertTrue(VoiceFallback.noOnDevice.contains("won't send audio anywhere"))
        XCTAssertTrue(VoiceFallback.speechDenied.contains("Speech Recognition"))
    }

    func testTheAppleEngineAlwaysRequiresOnDeviceAndWritesNothing() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/VoiceEngineTests.swift", with: "Sources/ForceIQPeak/AppleSpeech.swift")
        let src = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(src.contains("requiresOnDeviceRecognition = true"))
        XCTAssertTrue(src.contains("guard let r = Self.recognizer, r.supportsOnDeviceRecognition else { return }"), "no on-device support: no request at all")
        XCTAssertFalse(src.contains("AVAudioFile") || src.contains("write(") || src.contains("temporaryDirectory"), "audio stays in memory")
        let plist = try String(contentsOfFile: path.replacingOccurrences(of: "Sources/ForceIQPeak/AppleSpeech.swift", with: "Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("NSSpeechRecognitionUsageDescription") && plist.contains("NSMicrophoneUsageDescription"))
    }

    func testTheControllerFallsBackOnlyWhenParakeetFailsToLoad() throws {
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/VoiceEngineTests.swift", with: "Sources/ForceIQPeak/Voice.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8)
        let prepare = v.components(separatedBy: "func prepare() {").last?.components(separatedBy: "/// Parakeet didn't load").first ?? ""
        XCTAssertTrue(prepare.contains("me.value?.fallBackToAppleSpeech(error)"), "a load or download failure routes to the fallback")
        XCTAssertTrue(prepare.contains("self.dictation = self.engine; self.engineKind = .parakeet"), "a successful load is Parakeet again")
        XCTAssertFalse(v.contains("VoiceStrip"), "the strip that hung under the notch is gone")
    }

    // ── toggle states ──
    func testToggleIsOnePressStartsTheNextStops() {
        typealias T = VoiceToggle
        XCTAssertEqual(T.action(enabled: true, phase: .ready, briefSpeaking: false), .start)
        XCTAssertEqual(T.action(enabled: true, phase: .listening, briefSpeaking: false), .stop)
        XCTAssertEqual(T.action(enabled: true, phase: .needsModels, briefSpeaking: false), .prepare)
        XCTAssertEqual(T.action(enabled: true, phase: .failed("x"), briefSpeaking: false), .prepare)
        for busy in [VoicePhase.loading, .finishing, .downloading(fraction: 0.4, what: "m")] {
            XCTAssertEqual(T.action(enabled: true, phase: busy, briefSpeaking: false), .ignoreBusy, "\(busy)")
        }
        XCTAssertEqual(T.action(enabled: false, phase: .ready, briefSpeaking: false), .refuseOff)
        XCTAssertEqual(T.action(enabled: false, phase: .listening, briefSpeaking: false), .refuseOff)
        XCTAssertEqual(T.action(enabled: true, phase: .listening, briefSpeaking: true), .interruptBrief, "a press first silences the brief")
        XCTAssertEqual(T.action(enabled: false, phase: .off, briefSpeaking: true), .interruptBrief)
    }

    func testOnlyReadyAndListeningCanToggleAndThereAreNoOtherModes() throws {
        for p in [VoicePhase.off, .needsModels, .loading, .finishing, .failed("x"), .downloading(fraction: 0, what: "m")] { XCTAssertFalse(p.canToggle, "\(p)") }
        XCTAssertTrue(VoicePhase.ready.canToggle && VoicePhase.listening.canToggle)
        let path = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/VoiceEngineTests.swift", with: "Sources/ForceIQPeak/Voice.swift")
        let v = try String(contentsOfFile: path, encoding: .utf8).lowercased()
        XCTAssertFalse(v.contains("holdtotalk") || v.contains("wakeword") || v.contains("silencetimeout") || v.contains("autostop"), "no hold-to-talk, wake word or auto-stop")
    }

    func testAClickOnTheCaptionAndTheDictateShortcutBothToggle() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/VoiceEngineTests.swift", with: "Sources/ForceIQPeak/")
        let views = try String(contentsOfFile: base + "Views.swift", encoding: .utf8)
        XCTAssertTrue(views.contains("if captionShowing { Haptic.level(); voice.toggle() }"))
        let app = try String(contentsOfFile: base + "AppDelegate.swift", encoding: .utf8)
        XCTAssertTrue(app.contains("KeyboardShortcuts.onKeyUp(for: .dictate)") && app.contains("self?.voice.toggle()"))
        let support = try String(contentsOfFile: base + "Support.swift", encoding: .utf8)
        XCTAssertTrue(support.contains("static let dictate = KeyboardShortcuts.Name(\"dictatePeek\""))
    }

    // ── live caption text ──
    func testShortTextStaysOnTheLeftAndNothingIsCut() {
        XCTAssertEqual(LiveCaption.split("open Spiros").left, "open Spiros"); XCTAssertEqual(LiveCaption.split("open Spiros").right, "")
        XCTAssertEqual(LiveCaption.split("").left, ""); XCTAssertEqual(LiveCaption.split("   ").right, "")
    }

    func testLongerTextContinuesOnTheRightOfTheNotchInWholeWords() {
        let (l, r) = LiveCaption.split("open Spiros latest FLOW package")
        XCTAssertEqual(l, "open Spiros"); XCTAssertEqual(r, "latest FLOW package")
        XCTAssertLessThanOrEqual(l.count, LiveCaption.notchLeftChars); XCTAssertLessThanOrEqual(r.count, LiveCaption.notchRightChars)
        XCTAssertEqual(l + " " + r, "open Spiros latest FLOW package", "reading left to right across the notch loses nothing")
    }

    func testTextThatOutgrowsBothSidesScrollsTheOldestWordsOff() {
        let said = "open Spiros latest FLOW package and press the code button then start a meeting with Jelenic"
        let (l, r) = LiveCaption.split(said)
        XCTAssertTrue(l.hasPrefix("…"), "scrolled: a leading ellipsis")
        XCTAssertLessThanOrEqual(l.count, LiveCaption.notchLeftChars); XCTAssertLessThanOrEqual(r.count, LiveCaption.notchRightChars)
        XCTAssertTrue(r.hasSuffix("Jelenic"), "the newest word is always visible")
        for w in (l.dropFirst() + " " + r).split(separator: " ") { XCTAssertTrue(said.contains(w), "only real whole words: \(w)") }
    }

    func testAnOverlongSingleWordIsCutNeverCrashes() {
        let (l, r) = LiveCaption.split(String(repeating: "a", count: 80))
        XCTAssertLessThanOrEqual(l.count, LiveCaption.notchLeftChars + 1); XCTAssertLessThanOrEqual(r.count, LiveCaption.notchRightChars + 1)
        XCTAssertEqual(LiveCaption.tail("supercalifragilistic", maxChars: 8).count, 8)
    }

    func testPillShowsOneLineOfTheNewestWords() {
        let t = LiveCaption.tail("open Spiros latest FLOW package and press the code button then start a meeting with Jelenic please", maxChars: LiveCaption.pillChars)
        XCTAssertLessThanOrEqual(t.count, LiveCaption.pillChars); XCTAssertTrue(t.hasPrefix("…") && t.hasSuffix("please"))
        XCTAssertEqual(LiveCaption.tail("short", maxChars: 54), "short")
    }

    // ── measured fit: real 13 pt widths, no ellipsis cut by the view ──
    static var font: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
    static func measure(_ s: String) -> CGFloat { NSAttributedString(string: s, attributes: [.font: font]).size().width }

    func testEveryPrefixOfARealDictationFitsBesideTheNotchByMeasuredWidth() {
        let said = "Open Halliday's latest flow package and press the code button, then start a meeting with Jelenic tomorrow morning, check the invoice for last week, and send the family the link before practice starts."
        let words = said.split(separator: " ").map(String.init)
        for n in 1...words.count {
            let t = words.prefix(n).joined(separator: " ")
            let (l, r) = LiveCaption.split(t, leftWidth: LiveCaption.notchLeftPoints, rightWidth: LiveCaption.notchRightPoints, measure: Self.measure)
            XCTAssertLessThanOrEqual(Self.measure(l), LiveCaption.notchLeftPoints + 0.5, "left of \"\(t)\"")
            XCTAssertLessThanOrEqual(Self.measure(r), LiveCaption.notchRightPoints + 0.5, "right of \"\(t)\"")
            let shown = (l + " " + r).trimmingCharacters(in: .whitespaces).lowercased()
            XCTAssertTrue(shown.hasSuffix(words[n - 1].lowercased()), "the newest word is always visible: \"\(t)\" -> \"\(shown)\"")
        }
    }

    func testThePillTailFitsItsWidthByMeasure() {
        let said = "Open Halliday's latest flow package and press the code button, then start a meeting with Jelenic tomorrow morning, check the invoice for last week"
        let t = LiveCaption.tail(said, maxWidth: LiveCaption.pillPoints, measure: Self.measure)
        XCTAssertLessThanOrEqual(Self.measure(t), LiveCaption.pillPoints + 0.5); XCTAssertTrue(t.hasPrefix("…") && t.hasSuffix("last week"))
    }

    func testTheMeasuredBudgetsFitTheRealGeometry() {
        let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330), safeAreaTop: 43,
                                  auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43), auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))
        let l = PeakGeometry().layout(for: m5)
        let side = (l.peek.width - l.notchRect!.width) / 2
        XCTAssertLessThanOrEqual(LiveCaption.notchRightPoints, side - 14 - 12, "padding next to the notch and the caret")
        XCTAssertLessThanOrEqual(LiveCaption.notchLeftPoints, side - 14 - 16 - 8, "padding, the dot and its gap")
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440), safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertLessThanOrEqual(LiveCaption.pillPoints, PeakGeometry().layout(for: studio).peek.width - 32 - 16 - 8 - 12)
    }

    // ── layout: inside the notch row, nothing below, the characters fit ──
    func testTheCaptionRectIsInsideTheNotchRowOnTheM5() {
        let m5 = ScreenDescriptor(uuid: "M5", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 2048, height: 1330), safeAreaTop: 43,
                                  auxiliaryTopLeft: CGRect(x: 0, y: 1287, width: 899, height: 43), auxiliaryTopRight: CGRect(x: 1149, y: 1287, width: 899, height: 43))
        let l = PeakGeometry().layout(for: m5)
        let n = l.notchRect!
        XCTAssertEqual(l.peek.height, n.height, "exactly the notch's height: nothing hangs below it")
        XCTAssertEqual(l.peek.maxY, 1330); XCTAssertEqual(l.peek.minY, n.minY)
        XCTAssertEqual(l.peek.midX, n.midX, accuracy: 0.5)
        XCTAssertTrue(l.canvas.contains(l.peek))
        let side = (l.peek.width - n.width) / 2
        XCTAssertLessThanOrEqual(CGFloat(LiveCaption.notchRightChars) * 6.5, side - 14, "the right text fits beside the notch (13 pt, ~6.5 pt per character)")
        XCTAssertLessThanOrEqual(CGFloat(LiveCaption.notchLeftChars) * 6.5, side - 14 - 16, "the left text fits beside the dot")
    }

    func testTheStudioDisplayCaptionIsACompactPillInPlace() {
        let studio = ScreenDescriptor(uuid: "S", name: "Studio Display", frame: CGRect(x: 2048, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                      auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let l = PeakGeometry().layout(for: studio)
        XCTAssertEqual(l.mode, .pill); XCTAssertEqual(l.peek.height, l.collapsed.height); XCTAssertEqual(l.peek.minY, l.collapsed.minY)
        XCTAssertEqual(l.peek.midX, l.collapsed.midX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(CGFloat(LiveCaption.pillChars) * 6.5, l.peek.width - 32 - 16)
    }

    func testTheCaptionViewIsBrandWhiteOnBlackAndIsTheOnlyLiveWordsSurfaceWhenCollapsed() throws {
        let base = #filePath.replacingOccurrences(of: "Tests/PeakCoreTests/VoiceEngineTests.swift", with: "Sources/ForceIQPeak/")
        let v = try String(contentsOfFile: base + "Voice.swift", encoding: .utf8)
        let cap = v.components(separatedBy: "struct VoiceCaptionInline").last?.components(separatedBy: "struct ForcedVoiceFallback").first ?? ""
        XCTAssertTrue(cap.contains("Color.white") && cap.contains("Color.peakGreen") && cap.contains("Color.peakGold"))
        XCTAssertFalse(cap.contains("opacity") || cap.contains("gray") || cap.contains(".secondary") || cap.contains(".position("))
        let views = try String(contentsOfFile: base + "Views.swift", encoding: .utf8)
        XCTAssertFalse(views.contains("y: r.maxY + 26"), "nothing is positioned below the collapsed shape")
        XCTAssertTrue(views.contains("var surface: PeakLayout.Surface { isExpanded ? (showChat ? .chat : .home) : ((peekShowing || captionShowing) ? .peek : .collapsed) }"))
    }
}
