import AppKit
import CoreGraphics
import PeakCore
import Vision

// Proof captures for the Cua backend: ONE window only (screencapture -l <window id>), then redacted before anything is
// kept: Vision reads the text and every line that names a client (or, in strict mode, every line that isn't an
// allow-listed UI word) is filled black. The raw capture lives under ~/ForceIQ/peak-tmp/cua and is deleted at once;
// nothing is kept if the text can't be read (fail closed). Never requests Screen Recording: without it, no capture.
// Opt-in only (FORCEIQ_PEAK_CUA_PROOF_DIR, scratch proofs); never sent to Claude or anywhere else.

enum WindowCapture {
    static let keepWords: Set<String> = ["Code Window", "Tools", "Window", "File", "Edit", "View", "Help", "FLOW"]

    /// The frontmost on-screen, normal-layer window of `pid` (read-only window list; no titles read).
    static func windowID(pid: pid_t) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }

    /// nil = captured and redacted into `outDir`; otherwise why nothing was kept.
    static func captureRedacted(pid: pid_t, names: [String], strict: Bool, outDir: String, label: String) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return "no Screen Recording permission: no capture (never requested)" }
        guard let wid = windowID(pid: pid) else { return "no on-screen window for pid \(pid): no capture" }
        let tmp = (CuaConfig.tmp as NSString).expandingTildeInPath + "/raw-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard let args = CuaCapture.arguments(windowID: wid, out: tmp) else { return "no window: no capture" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        do { try p.run(); p.waitUntilExit() } catch { return "screencapture didn't run" }
        guard p.terminationStatus == 0, let img = NSImage(contentsOfFile: tmp)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "screencapture failed: no capture"
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        do { try VNImageRequestHandler(cgImage: img).perform([req]) } catch { return "text couldn't be read: capture dropped (fail closed)" }
        let lines: [(text: String, box: CGRect)] = (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox) } }
        guard !lines.isEmpty else { return "no text read: capture dropped (fail closed)" }
        let boxes = CuaCapture.redactions(lines, names: names, keepOnly: strict ? keepWords : nil)
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "redaction failed: capture dropped" }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for b in boxes {
            ctx.fill(CGRect(x: b.minX * Double(w) - 4, y: b.minY * Double(h) - 4, width: b.width * Double(w) + 8, height: b.height * Double(h) + 8))
        }
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            return "redaction failed: capture dropped"
        }
        let dest = (outDir as NSString).appendingPathComponent("\(label)-window\(wid)-redacted.png")
        do { try png.write(to: URL(fileURLWithPath: dest)) } catch { return "couldn't save the redacted capture" }
        return nil
    }
}
