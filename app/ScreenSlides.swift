// Mac: watches the lecture window for slides. The window is chosen in macOS's own picker, so the
// app needs no screen-recording permission (macOS 14 may still want it for its picker: when no window
// is chosen, the page shows how to allow it) and never sees anything else on the screen.

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
        s.startCapture { [weak self] error in
            guard let error else { return }
            log("slides: capture failed: \(error)")
            let declined = (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.Code.userDeclined.rawValue
            Task { @MainActor in
                guard let self else { return }
                if declined {                                            // macOS refused: how to allow it, and pick again
                    self.stream = nil
                    self.onNote?("slides_denied", "")
                } else {
                    self.onNote?("slides_note", L("슬라이드를 모으지 못했습니다. 받아쓰기는 계속됩니다.", "Couldn't collect slides. Transcription continues."))
                }
            }
        }
        log("slides: watching \(cfg.width)×\(cfg.height)")
        onNote?("slides_on", L("슬라이드를 모으고 있습니다. 바뀔 때마다 한 장씩 PDF에 담습니다.", "Collecting slides. Each time the slide changes, it's added to the PDF as a page."))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let img = self.latest.take() { self.onFrame?(img) } }
        }
    }

    /// Tests (LECTURE_FAKE_SCREEN): a video plays the part of the lecture window, in real time, two frames a second.
    private var fake: Task<Void, Never>?
    private func playFake(_ url: URL) {
        log("slides: watching a test video \(url.lastPathComponent)")
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
