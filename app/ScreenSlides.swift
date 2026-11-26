// Mac: watches the lecture window for slides. The window is chosen in macOS's own picker, so the
// app needs no screen-recording permission (macOS 14 may still want it for its picker: when no window
// is chosen, the page shows how to allow it) and never sees anything else on the screen.
//
// macOS hands over the chosen window wherever it is — on another desktop, behind other windows — but the app showing
// it stops drawing a window nobody can see (Chrome, Edge, Whale, Safari… on another desktop, in another app's full
// screen, minimized): until it's back in view there is nothing new to capture. So the window is watched: when it's out
// of sight the page says so (and how to keep slides coming: Picture in Picture stays on every desktop).

#if os(macOS)
import AppKit
import AVFoundation
import ScreenCaptureKit
import VideoToolbox

@MainActor
final class ScreenSlides: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    /// A frame for the slide detector (about twice a second, also while nothing changes).
    var onFrame: ((CGImage) -> Void)?
    /// Something to tell the user: (notice code, message).
    var onNote: ((String, String) -> Void)?
    /// The lecture window left the screen or came back: (visible, seconds it was out of sight, the app it belongs to).
    var onSight: ((Bool, Double, String?) -> Void)?

    private var stream: SCStream?
    private var timer: Timer?
    private var active = false
    private let queue = DispatchQueue(label: "lecture.screen", qos: .utility)
    private final class Latest: @unchecked Sendable {
        private let lock = NSLock(); private var image: CGImage?
        func set(_ i: CGImage) { lock.lock(); image = i; lock.unlock() }
        func take() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }
        func clear() { lock.lock(); image = nil; lock.unlock() }
    }
    private let latest = Latest()

    /// Shows the picker; capture starts once a window (or a display) is chosen. `again`: 창 다시 고르기 on the page.
    func start(again: Bool = false) {
        guard !active else { return }
        active = true
        retried = again
        latest.clear()                                                   // nothing left over from an earlier session
        if let mode = env["LECTURE_TEST_PICKER"], !again { simulatePicker(mode); return }        // tests: its answer
        if let path = env["LECTURE_FAKE_SCREEN"] { playFake(URL(fileURLWithPath: path)); return }   // tests: no picker
        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = [.singleWindow, .singleDisplay]
        if let me = Bundle.main.bundleIdentifier { cfg.excludedBundleIDs = [me] }
        picker.defaultConfiguration = cfg
        picker.add(self)
        picker.isActive = true
        picker.present()
        waitForPick()
    }

    /// 창 다시 고르기 (the page's button, while recording with 슬라이드 PDF): the picker once more — after it was
    /// cancelled, failed or never showed up; with a window already being watched, to switch to another one.
    func pickAgain() {
        log("slides: picker again")
        if active, stream != nil, fake == nil { SCContentSharingPicker.shared.present(); return }
        stop()
        start(again: true)
    }

    /// No answer from the picker for a while — no window chosen, not cancelled: it may never have appeared (macOS 14
    /// can show none without the Screen Recording permission). The page then says how to get it (steps, 창 다시 고르기,
    /// the Privacy pane); a window chosen later still starts the slides and clears that notice.
    private var pickWait: Timer?
    private static let pickWaitSeconds = env["LECTURE_TEST_PICK_WAIT"].flatMap(Double.init) ?? 20
    private func waitForPick() {
        pickWait?.invalidate()
        pickWait = Timer.scheduledTimer(withTimeInterval: Self.pickWaitSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, self.stream == nil, self.fake == nil else { return }
                log("slides: no window chosen after \(Int(Self.pickWaitSeconds)) s")
                self.onNote?("slides_picker", "")
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        unwatch()
        pickWait?.invalidate(); pickWait = nil
        fake?.cancel(); fake = nil
        timer?.invalidate(); timer = nil
        if let s = stream { s.stopCapture { _ in } }
        stream = nil
        latest.clear()
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func begin(_ filter: SCContentFilter) {
        guard active else { return }
        if let s = stream { s.stopCapture { _ in } }                    // picked again: switch to the new window
        let cfg = SCStreamConfiguration()
        let px = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                        height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let k = min(1, 1920 / max(px.width, px.height, 1))
        cfg.width = max(2, Int(px.width * k))
        cfg.height = max(2, Int(px.height * k))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)        // two frames a second is plenty for slides
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.queueDepth = 3
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            onNote?("slides_note", L("슬라이드를 모으지 못했습니다. 받아쓰기는 계속됩니다.", "Couldn't collect slides. Transcription continues."))
            return
        }
        stream = s
        let id = ObjectIdentifier(s)
        s.startCapture { [weak self] error in
            if let error { log("slides: capture failed: \(error)") }
            let ok = error == nil
            let declined = (error as NSError?).map { $0.domain == SCStreamErrorDomain && $0.code == SCStreamError.Code.userDeclined.rawValue } ?? false
            Task { @MainActor in                                         // stopped or switched to another window meanwhile: old news
                guard let self, self.active, self.stream.map(ObjectIdentifier.init) == id else { return }
                if ok {                                                  // said only once frames can come
                    self.onNote?("slides_on", L("슬라이드를 모으고 있습니다. 바뀔 때마다 한 장씩 PDF에 담습니다.", "Collecting slides. Each time the slide changes, it's added to the PDF as a page."))
                } else if declined {                                     // macOS refused: how to allow it, and pick again
                    self.stream = nil
                    self.onNote?("slides_denied", "")
                } else {
                    self.onNote?("slides_note", L("슬라이드를 모으지 못했습니다. 받아쓰기는 계속됩니다.", "Couldn't collect slides. Transcription continues."))
                }
            }
        }
        log("slides: watching \(cfg.width)×\(cfg.height)")
        watch(filter)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let img = self.latest.take() { self.onFrame?(img) } }
        }
    }

    /// Tests (LECTURE_FAKE_SCREEN): a video plays the part of the lecture window, in real time, two frames a second.
    private var fake: Task<Void, Never>?
    private func playFake(_ url: URL) {
        log("slides: watching a test video \(url.lastPathComponent)")
        watch(nil)                                                       // LECTURE_TEST_WATCH_WINDOW: a window to watch
        fake = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            let start = Date()
            var t = 0.0
            while t < duration, !Task.isCancelled {
                if let frame = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, let self, self.active {
                    self.onFrame?(frame)
                }
                t += 0.5
                let wait = start.addingTimeInterval(t).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
        onNote?("slides_on", L("슬라이드를 모으고 있습니다. 바뀔 때마다 한 장씩 PDF에 담습니다.", "Collecting slides. Each time the slide changes, it's added to the PDF as a page."))
    }

    /// Tests (LECTURE_TEST_PICKER): how the picker answers — "silent" (never shows, never answers), "cancel", "fail",
    /// or "denied" (a window chosen, macOS refuses the capture). 창 다시 고르기 then plays LECTURE_FAKE_SCREEN, as if
    /// a window was chosen the second time.
    private var retried = false
    private func simulatePicker(_ mode: String) {
        log("slides: test picker \(mode)")
        waitForPick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active, !self.retried else { return }
                switch mode {
                case "cancel": self.contentSharingPicker(SCContentSharingPicker.shared, didCancelFor: nil)
                case "fail": self.contentSharingPickerStartDidFailWithError(NSError(domain: "test", code: 1))
                case "denied": self.pickWait?.invalidate(); self.onNote?("slides_denied", "")
                default: break                                           // "silent": the wait runs out
                }
            }
        }
    }

    // MARK: in sight

    private var watched: CGWindowID?
    private var watchedApp: String?
    private var sightTimer: Timer?
    private var spaceWatch: NSObjectProtocol?
    private var outSince: Date?
    private var toldOut = false
    /// A quick look at another desktop says nothing (Chrome itself waits a second before it stops drawing).
    private static let sightGrace = env["LECTURE_TEST_SIGHT_GRACE"].flatMap(Double.init) ?? 3

    /// Watches the chosen window (a display needs no watching: it shows whatever is on it). macOS 15.2+ names the
    /// picked window; before that, it's the one window of another app with the picked size (none or several: not watched).
    private func watch(_ filter: SCContentFilter?) {
        unwatch()
        var id = env["LECTURE_TEST_WATCH_WINDOW"].flatMap { UInt32($0) }
        if id == nil, let filter, filter.style == .window {
            if #available(macOS 15.2, *) { id = filter.includedWindows.first?.windowID }
            if id == nil { id = Self.window(at: filter.contentRect) }
        }
        guard let id else { log("slides: not watched for sight (\(filter.map { $0.style == .display ? "a display" : "window unknown" } ?? "test"))"); return }
        watched = id
        watchedApp = Self.owner(of: id)
        log("slides: watching window \(id) (\(watchedApp ?? "?")) for sight")
        sightTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSight() }
        }
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSight() }
        }
    }

    /// The watch ends (another window was picked, or the capture stopped): a page told "out of sight" hears that it's
    /// over (0 s: nothing came back, so nothing to report).
    private func unwatch() {
        sightTimer?.invalidate(); sightTimer = nil
        if let o = spaceWatch { NSWorkspace.shared.notificationCenter.removeObserver(o); spaceWatch = nil }
        if toldOut { onSight?(true, 0, watchedApp) }
        watched = nil; watchedApp = nil; outSince = nil; toldOut = false
    }

    private func checkSight() {
        guard active, let id = watched else { return }
        if !Self.onScreen(id) {
            if outSince == nil { outSince = Date(); log("slides: window \(id) out of sight") }
            if !toldOut, let since = outSince, Date().timeIntervalSince(since) >= Self.sightGrace {
                toldOut = true
                onSight?(false, Date().timeIntervalSince(since), watchedApp)
            }
        } else if let since = outSince {
            let secs = Date().timeIntervalSince(since)
            log("slides: window \(id) back in sight after \(Int(secs)) s")
            if toldOut { onSight?(true, secs, watchedApp) }
            outSince = nil; toldOut = false
        }
    }

    static func windowInfo(_ id: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
    }
    /// The app a window belongs to ("Google Chrome") — also while it's minimized or on another desktop.
    static func owner(of id: CGWindowID) -> String? {
        if let name = windowInfo(id)?[kCGWindowOwnerName as String] as? String { return name }
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }?[kCGWindowOwnerName as String] as? String
    }
    /// On the screen now — behind other windows still counts: not on another desktop or in another app's full screen,
    /// not minimized, its app not hidden (macOS then lists it as off screen, or not at all).
    static func onScreen(_ id: CGWindowID) -> Bool { windowInfo(id)?[kCGWindowIsOnscreen as String] as? Bool ?? false }
    /// macOS 14.2–15.1 (the filter doesn't name its window, but its frame is the window's): the on-screen window of
    /// another app at that frame — or, failing that, the one with that size; nil when none or several.
    static func window(at frame: CGRect) -> CGWindowID? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.compactMap { w -> (CGWindowID, CGRect)? in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: Double], let n = w[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (CGWindowID(n.uint32Value), CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) < 2 }
        let sized = mine.filter { near($0.1.width, frame.width) && near($0.1.height, frame.height) }
        let placed = sized.filter { near($0.1.minX, frame.minX) && near($0.1.minY, frame.minY) }
        return placed.count == 1 ? placed[0].0 : sized.count == 1 ? sized[0].0 : nil
    }

    // MARK: picker

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.pickWait?.invalidate()
            self.begin(filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.active, self.stream == nil else { return }
            self.pickWait?.invalidate()
            self.onNote?("slides_canceled", L("강의 창을 선택하지 않아서 슬라이드 없이 받아 적습니다.", "No lecture window was chosen. Transcribing without slides."))
            self.stop()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            log("slides: picker failed: \(error)")
            self.pickWait?.invalidate()
            self.onNote?("slides_picker_failed", L("창 선택을 열지 못했습니다. 슬라이드 없이 받아 적습니다.", "Couldn't open the window picker. Transcribing without slides."))
            self.stop()
        }
    }

    // MARK: stream

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
        if let image { latest.set(image) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("slides: stream stopped: \(error)")
        Task { @MainActor in
            guard self.active else { return }
            self.onNote?("slides_note", L("강의 창이 닫혀서 슬라이드 모으기를 멈췄습니다. 받아쓰기는 계속됩니다.", "The lecture window was closed, so slide collection stopped. Transcription continues."))
            self.stop()
        }
    }
}
#endif
