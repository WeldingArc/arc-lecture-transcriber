// Mac: the Settings window (⌘, and the gear on the main screen) — macOS's own controls in toolbar tabs, like the system's
// apps. It shows and changes the same settings as the page did (through Bridge.handle) and follows the engine's events,
// so the main window and this one always agree. The iPhone/iPad app keeps the page's own settings.

#if os(macOS)
import AppKit
import SwiftUI

/// What the Settings window does through the app: change settings, run a page command, show something in the main window.
@MainActor
protocol SettingsHost: AnyObject {
    func settingsChange(_ body: [String: Any])                 // Bridge.handle("settings", …)
    func settingsCommand(_ cmd: String, _ body: [String: Any]) // Bridge.handle(cmd, …): engines, storage, links, logs
    func settingsShowInMain(_ ev: String)                      // the page shows it: "openLegal", "openSlideDemo"
}

/// Everything the Settings window shows, kept current from the events the engine sends the page.
@MainActor
final class SettingsStore: ObservableObject {
    struct EngineRow: Identifiable, Equatable {
        let id: String, name: String, model: String, desc: String, state: String, error: String
        let progress: Double, bytes: Int64, removable: Bool, verifying: Bool, languages: [String]?
    }
    struct Storage: Equatable { let count: Int, bytes: Int64, folder: String }

    weak var host: SettingsHost?
    @Published var lang = appLanguage.value                    // the app's language: every label is drawn in it
    @Published var theme = "dark"
    @Published var accent = "brass"
    @Published var size = "m"
    @Published var icon = "navy"
    @Published var uiLanguage = appLanguage.value
    @Published var chosen = AppLanguage.chosen != nil          // false: the app follows the Mac's language
    @Published var timestamps = true
    @Published var slides = false
    @Published var cleanCapture = true
    @Published var pdfLayout = "landscape"
    @Published var keywords: [String] = []
    @Published var lecture = "ko"                              // the lecture language (an English-only engine sits out others)
    @Published var engines: [EngineRow] = []
    @Published var currentEngine = "apple"
    @Published var enginesBusy = false
    @Published var transcribing = false                        // recording, or transcribing a file: the language stays
    @Published var storage: Storage?

    /// An event the engine sent the page.
    func receive(_ ev: [String: Any]) {
        switch ev["ev"] as? String {
        case "settings":
            func str(_ k: String) -> String? { ev[k] as? String }
            if let v = str("theme"), v != theme { theme = v }
            if let v = str("accent"), v != accent { accent = v }
            if let v = str("size"), v != size { size = v }
            if let v = str("icon"), v != icon { icon = v }
            if let v = str("uiLanguage"), v != uiLanguage { uiLanguage = v }
            if let v = ev["uiLanguageChosen"] as? Bool, v != chosen { chosen = v }
            if let v = ev["timestamps"] as? Bool, v != timestamps { timestamps = v }
            if let v = ev["slides"] as? Bool, v != slides { slides = v }
            if let v = ev["cleanCapture"] as? Bool, v != cleanCapture { cleanCapture = v }
            if let v = str("pdfLayout"), v != pdfLayout { pdfLayout = v }
            if let v = ev["keywords"] as? [String], v != keywords { keywords = v }
            if let v = str("language"), v != lecture { lecture = v }
        case "engines":
            func num(_ x: Any?) -> Double { (x as? NSNumber)?.doubleValue ?? 0 }
            let rows = (ev["list"] as? [[String: Any]] ?? []).map { e in
                EngineRow(id: e["id"] as? String ?? "", name: e["name"] as? String ?? "", model: e["model"] as? String ?? "",
                          desc: e["desc"] as? String ?? "", state: e["state"] as? String ?? "absent", error: e["error"] as? String ?? "",
                          progress: num(e["progress"]), bytes: Int64(num(e["bytes"])), removable: e["removable"] as? Bool ?? false,
                          verifying: e["verifying"] as? Bool ?? false, languages: e["languages"] as? [String])
            }
            if rows != engines { engines = rows }
            let cur = ev["current"] as? String ?? "apple"
            if cur != currentEngine { currentEngine = cur }
            let busy = ev["busy"] as? Bool ?? false
            if busy != enginesBusy { enginesBusy = busy }
        case "rec":
            let on = (ev["state"] as? String ?? "idle") != "idle"
            if on != transcribing { transcribing = on }
        case "storage":
            storage = Storage(count: (ev["count"] as? NSNumber)?.intValue ?? 0, bytes: (ev["bytes"] as? NSNumber)?.int64Value ?? 0,
                              folder: ev["folder"] as? String ?? "")
        default: break
        }
    }

    /// A setting changed here: shown at once, then confirmed by the engine's event.
    func set(_ key: String, _ value: Any) {
        switch key {
        case "theme": theme = value as? String ?? theme
        case "accent": accent = value as? String ?? accent
        case "size": size = value as? String ?? size
        case "icon": icon = value as? String ?? icon
        case "timestamps": timestamps = value as? Bool ?? timestamps
        case "slides": slides = value as? Bool ?? slides
        case "cleanCapture": cleanCapture = value as? Bool ?? cleanCapture
        case "pdfLayout": pdfLayout = value as? String ?? pdfLayout
        case "keywords": keywords = value as? [String] ?? keywords
        default: break
        }
        host?.settingsChange([key: value])
    }

    func command(_ cmd: String, _ body: [String: Any] = [:]) { host?.settingsCommand(cmd, body) }

    /// The engine a recording would use now — a downloaded one sits out a lecture language it doesn't write.
    var engineInUse: EngineRow? {
        guard let e = engines.first(where: { $0.id == currentEngine && $0.id != "apple" && $0.state == "ready" }) else { return nil }
        return e.languages.map { $0.contains(lecture) } ?? true ? e : nil
    }
}

// MARK: - helpers

/// The accents of the page's themes: [dark, light] (light ones read as text on light cards).
private let accentHex: [(String, UInt32, UInt32)] = [("brass", 0xc9a96b, 0x7c5f2c), ("sage", 0x8fae8b, 0x466d4d), ("rose", 0xd39a94, 0x984f47),
                                                     ("blue", 0x8fb0e0, 0x3a64a6), ("lavender", 0xb3a6e0, 0x6757ae)]
private func hexColor(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
}
private func themeAccent(_ name: String, dark: Bool) -> Color {
    let a = accentHex.first { $0.0 == name } ?? accentHex[0]
    return hexColor(dark ? a.1 : a.2)
}
private func accentName(_ k: String) -> String {
    switch k {
    case "sage": return L("세이지", "Sage")
    case "rose": return L("로즈", "Rose")
    case "blue": return L("블루", "Blue")
    case "lavender": return L("라벤더", "Lavender")
    default: return L("브라스", "Brass")
    }
}
private let iconNames: [(String, () -> String)] = [("navy", { L("네이비", "Navy") }), ("ivory", { L("아이보리", "Ivory") }),
                                                   ("brass", { L("브라스", "Brass") }), ("charcoal", { L("차콜", "Charcoal") }),
                                                   ("sage", { L("세이지", "Sage") })]
/// The 12 languages, each in its own words (as on the start screen's globe).
let uiLanguageNames: [(String, String)] = [("ko", "한국어"), ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
                                           ("ja", "日本語"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
                                           ("pt-BR", "Português (Brasil)"), ("it", "Italiano"), ("vi", "Tiếng Việt"), ("ru", "Русский")]

/// A size as the page writes it: "574MB", "1.2GB" (Korean, English); a localized number and unit in the other languages.
func sizeText(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1e6, gb = mb >= 1000
    let lang = appLanguage.value
    if lang == "ko" || lang == "en" { return gb ? String(format: "%.1fGB", mb / 1000) : "\(Int(mb.rounded()))MB" }
    let f = NumberFormatter()
    f.locale = Locale(identifier: lang)
    f.minimumFractionDigits = gb ? 1 : 0
    f.maximumFractionDigits = gb ? 1 : 0
    let unit = ["fr": ["MB": "Mo", "GB": "Go"], "ru": ["MB": "МБ", "GB": "ГБ"]][lang]?[gb ? "GB" : "MB"] ?? (gb ? "GB" : "MB")
    return (f.string(from: NSNumber(value: gb ? mb / 1000 : mb.rounded())) ?? "\(Int(mb))") + "\u{00A0}" + unit
}

/// "Downloads › 강의기록": the folder and the one it's in, the first in the app's language.
private func folderLabel(_ path: String) -> String {
    let parts = (path as NSString).pathComponents.filter { $0 != "/" }.suffix(2)
    return parts.enumerated().map { i, x in
        guard i == 0 && parts.count == 2 else { return x }
        switch x {
        case "Downloads": return L("다운로드", "Downloads")
        case "Documents": return L("문서", "Documents")
        case "Desktop": return L("데스크탑", "Desktop")
        default: return x
        }
    }.joined(separator: " › ")
}

private struct Caption: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// The accent of the app's theme on the controls that show a choice (switches, the theme's segments, a download's bar);
/// buttons keep macOS's own look.
private struct AccentTint: ViewModifier {
    @ObservedObject var s: SettingsStore
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.tint(themeAccent(s.accent, dark: scheme == .dark)) }
}
private extension View {
    func accent(_ s: SettingsStore) -> some View { modifier(AccentTint(s: s)) }
}

// MARK: - 일반

private struct GeneralTab: View {
    @ObservedObject var s: SettingsStore
    @Environment(\.colorScheme) private var scheme

    private var language: Binding<String> {
        Binding(get: { s.chosen ? s.uiLanguage : "system" }, set: { v in
            guard v != (s.chosen ? s.uiLanguage : "system") else { return }
            s.host?.settingsChange(["uiLanguage": v])
        })
    }
    private func pick(_ key: String, _ current: String) -> Binding<String> {
        Binding(get: { current }, set: { s.set(key, $0) })
    }

    var body: some View {
        let _ = s.lang
        Form {
            Section {
                Picker(L("언어", "Language"), selection: language) {
                    Text(L("Mac과 같게", "Same as the Mac") + " (\(uiLanguageNames.first { $0.0 == AppLanguage.followed }?.1 ?? "English"))").tag("system")
                    Divider()
                    ForEach(uiLanguageNames, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(s.transcribing)
            } footer: {
                Caption(text: s.transcribing ? L("받아 적는 동안에는 언어를 바꿀 수 없습니다.", "You can't change the language while transcribing.")
                                             : L("메뉴 막대의 앱 이름과 열기 창 같은 시스템 화면은 앱을 다시 열면 바뀝니다.", "The app's name in the menu bar and system windows such as Open change the next time you open the app."))
            }
            Section(L("화면", "Appearance")) {
                Picker(L("테마", "Theme"), selection: pick("theme", s.theme)) {
                    Text(L("시스템", "System")).tag("system")
                    Text(L("다크", "Dark")).tag("dark")
                    Text(L("라이트", "Light")).tag("light")
                }
                .pickerStyle(.segmented)
                .accent(s)
                LabeledContent(L("강조 색", "Accent Color")) {
                    HStack(spacing: 12) {
                        ForEach(accentHex, id: \.0) { a in
                            Button { s.set("accent", a.0) } label: {
                                Circle().fill(themeAccent(a.0, dark: scheme == .dark)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(a.0 == s.accent ? 0.8 : 0), lineWidth: 2).padding(-4))
                                    .padding(4).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accentName(a.0))
                            .accessibilityAddTraits(a.0 == s.accent ? .isSelected : [])
                            .help(accentName(a.0))
                        }
                    }
                }
                Picker(L("글자 크기", "Text Size"), selection: pick("size", s.size)) {
                    Text(L("작게", "Small")).tag("s")
                    Text(L("보통", "Medium")).tag("m")
                    Text(L("크게", "Large")).tag("l")
                    Text(L("아주 크게", "Largest")).tag("xl")
                }
            }
            Section {
                HStack(spacing: 0) {
                    ForEach(iconNames, id: \.0) { n in
                        Button { s.set("icon", n.0) } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: NSImage(contentsOfFile: uiDir + "/icons/\(n.0).png") ?? NSImage())
                                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.tint, lineWidth: n.0 == s.icon ? 2.5 : 0).padding(-4))
                                Text(n.1()).font(.caption).foregroundStyle(n.0 == s.icon ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(n.0 == s.icon ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
                .accent(s)
            } header: {
                Text(L("앱 아이콘", "App Icon"))
            } footer: {
                Caption(text: L("Dock의 아이콘이 바로 바뀝니다. Finder 등 다른 곳의 아이콘은 그대로입니다.", "The Dock icon changes right away. Elsewhere, such as in Finder, the icon stays the same."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 받아쓰기

private struct TranscriptionTab: View {
    @ObservedObject var s: SettingsStore
    @State private var editing = false
    @State private var draft = ""

    private func on(_ key: String, _ current: Bool) -> Binding<Bool> { Binding(get: { current }, set: { s.set(key, $0) }) }
    private var pdfInfo: String {
        switch s.pdfLayout {
        case "split": return L("슬라이드만 담은 PDF와 받아쓰기 PDF, 두 파일로 저장합니다.", "One PDF with only the slides, and a second with the transcript.")
        case "classic": return L("A4 한 쪽에 슬라이드와 그때 한 말을 함께 담습니다(이전 방식).", "A slide and what was said, together on an A4 page (the earlier layout).")
        default: return L("슬라이드가 가로 한 쪽을 가득 채우고, 다음 쪽에 그때 한 말을 담습니다.", "Each slide fills a landscape page; what was said follows on the next page.")
        }
    }
    /// "출석, 시험, 과제 and 13 more" (Korean words last in another language), or 없음.
    private var keywordSummary: String {
        let k = s.keywords
        guard !k.isEmpty else { return L("없음", "None") }
        let order = appLanguage.value == "ko" ? k : k.filter { $0.range(of: "\\p{Hangul}", options: .regularExpression) == nil }
                                                  + k.filter { $0.range(of: "\\p{Hangul}", options: .regularExpression) != nil }
        return order.prefix(3).joined(separator: ", ") + (k.count > 3 ? L(" 외 \(k.count - 3)개", " and \(k.count - 3) more") : "")
    }

    var body: some View {
        let _ = s.lang
        Form {
            Section {
                Toggle(isOn: on("timestamps", s.timestamps)) {
                    Text(L("시간 표시", "Show Times"))
                    Caption(text: L("문장 앞에 강의 시간을 붙입니다", "Adds the lecture time before each sentence"))
                }
                .accent(s)
            }
            Section(L("슬라이드 PDF", "Slide PDF")) {
                Toggle(isOn: on("slides", s.slides)) {
                    Text(L("슬라이드 PDF", "Slide PDF"))
                    Caption(text: L("강의 창의 슬라이드를 모아 한 말과 함께 PDF로", "Collects the lecture window's slides into a PDF with what was said"))
                }
                .accent(s)
                Picker(selection: Binding(get: { s.pdfLayout }, set: { s.set("pdfLayout", $0) })) {
                    Text(L("가로", "Landscape")).tag("landscape")
                    Text(L("두 파일", "Two Files")).tag("split")
                    Text(L("A4 한 쪽", "A4 Page")).tag("classic")
                } label: {
                    Text(L("PDF 형식", "PDF Layout"))
                    Caption(text: pdfInfo)
                }
                .disabled(!s.slides)
                Toggle(isOn: on("cleanCapture", s.cleanCapture)) {
                    Text(L("깔끔하게 담기", "Clean Capture"))
                    Caption(text: L("주소창·플레이어·검은 여백을 빼고 슬라이드만 PDF에 담습니다", "Leaves out the browser bar, player and black borders — only the slide goes into the PDF"))
                }
                .disabled(!s.slides)
                .accent(s)
                LabeledContent {
                    Button(L("보기", "Show")) { s.host?.settingsShowInMain("openSlideDemo") }
                } label: {
                    Text(L("슬라이드 PDF 작동 방식", "How Slide PDF Works"))
                }
            }
            Section(L("중요 단어", "Key Words")) {
                LabeledContent {
                    Button(L("편집…", "Edit…")) { draft = s.keywords.joined(separator: ", "); editing = true }
                } label: {
                    Text(keywordSummary).lineLimit(2)
                    Caption(text: L("이 단어가 들어간 문장은 밑줄로 표시되고, 저장 파일과 전체 복사 끝에 ‘중요 문장’으로 모아집니다. 쉼표로 구분하십시오.",
                                    "Sentences containing these words are underlined and collected under Key Sentences at the end of the saved file and the Copy All text. Separate words with commas."))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {                                                     // tests: the key words sheet open
            if env["LECTURE_TEST_KW_SHEET"] == "1" { draft = s.keywords.joined(separator: ", "); editing = true }
        }
        .sheet(isPresented: $editing) {
            KeywordSheet(draft: $draft, done: { save in
                editing = false
                if save {
                    let words = draft.components(separatedBy: CharacterSet(charactersIn: ",\n、，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    s.set("keywords", words)
                }
            })
        }
    }
}

private struct KeywordSheet: View {
    @Binding var draft: String
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("중요 단어", "Key Words")).font(.headline)
            Caption(text: L("이 단어가 들어간 문장은 밑줄로 표시되고, 저장 파일과 전체 복사 끝에 ‘중요 문장’으로 모아집니다. 쉼표로 구분하십시오.",
                            "Sentences containing these words are underlined and collected under Key Sentences at the end of the saved file and the Copy All text. Separate words with commas."))
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Button(L("기본값", "Restore Defaults")) { draft = defaultKeywords.joined(separator: ", ") }
                Spacer()
                Button(L("취소", "Cancel"), role: .cancel) { done(false) }.keyboardShortcut(.cancelAction)
                Button(L("저장", "Save")) { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 음성 인식

private struct EngineRowView: View {
    let e: SettingsStore.EngineRow
    @ObservedObject var s: SettingsStore
    @State private var confirmDelete = false

    private var note: String {
        let ready = e.state == "ready", on = ready && e.id == s.currentEngine
        let pct = Int((e.progress * 100).rounded(.down))
        if e.state == "failed" { return e.error.isEmpty ? L("내려받지 못했습니다.", "Download failed.") : e.error }
        if e.state == "downloading" {
            return e.verifying ? L("내려받은 모델을 확인하고 준비하는 중…", "Checking and preparing the downloaded model…")
                : L("내려받는 중 · \(pct)% · \(sizeText(Int64(e.progress * Double(e.bytes)))) / \(sizeText(e.bytes))",
                    "Downloading · \(pct)% · \(sizeText(Int64(e.progress * Double(e.bytes)))) / \(sizeText(e.bytes))")
        }
        if on, let langs = e.languages, !langs.contains(s.lecture) {              // English-only, a Korean lecture
            return langs.count > 1 ? L("한국어와 영어 강의일 때 사용합니다 · 지금 강의 언어는 Apple 음성 인식으로 받아 적습니다", "Used for Korean and English lectures · Apple Speech Recognition transcribes the current lecture language")
                : s.lecture == "ko" ? L("영어 강의일 때 사용합니다 · 지금은 한국어 강의라 Apple 음성 인식으로 받아 적습니다", "Used for English lectures · The lecture language is Korean, so Apple Speech Recognition is used for now")
                : L("영어 강의일 때 사용합니다 · 지금 강의 언어는 Apple 음성 인식으로 받아 적습니다", "Used for English lectures · Apple Speech Recognition transcribes the current lecture language")
        }
        return e.desc
    }

    var body: some View {
        let ready = e.state == "ready", on = ready && e.id == s.currentEngine
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accent(s)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.name)
                    if !e.model.isEmpty { Text(e.model).font(.callout).foregroundStyle(.secondary) }
                }
                Text(note).font(.callout).foregroundStyle(e.state == "failed" ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if e.state == "downloading" { ProgressView(value: e.verifying ? 1 : e.progress).frame(maxWidth: 240).accent(s) }
            }
            Spacer(minLength: 8)
            Group {
                if on {
                    HStack(spacing: 8) {
                        Text(L("사용 중", "In Use")).font(.callout).foregroundStyle(.secondary)
                        if e.removable { Button(L("삭제", "Delete")) { confirmDelete = true } }   // Apple's is part of macOS
                    }
                } else if ready {
                    HStack(spacing: 8) {
                        Button(L("사용", "Use")) { s.command("engineSelect", ["engine": e.id]) }
                        if e.removable {
                            Button(L("삭제", "Delete")) { confirmDelete = true }
                        }
                    }
                } else if e.state == "absent" {
                    Button(L("내려받기 · \(sizeText(e.bytes))", "Download · \(sizeText(e.bytes))")) { s.command("engineDownload", ["engine": e.id]) }
                } else if e.state == "failed" {
                    Button(L("다시 시도", "Try Again")) { s.command("engineDownload", ["engine": e.id]) }
                } else if e.state == "downloading" && !e.verifying {
                    Button(L("취소", "Cancel")) { s.command("engineCancel", ["engine": e.id]) }
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .alert(L("\(e.name) 모델 삭제", "Delete \(e.name) Model"), isPresented: $confirmDelete) {
            Button(L("삭제", "Delete"), role: .destructive) { s.command("engineRemove", ["engine": e.id]) }
            Button(L("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("내려받은 모델(\(sizeText(e.bytes)))을 삭제하시겠습니까? 다시 사용하려면 다시 내려받아야 합니다.",
                   "Delete the downloaded model (\(sizeText(e.bytes)))? You'll need to download it again to use it."))
        }
    }
}

private struct SpeechTab: View {
    @ObservedObject var s: SettingsStore
    var body: some View {
        let _ = s.lang
        Form {
            Section {
                ForEach(s.engines) { EngineRowView(e: $0, s: s) }
            } footer: {
                Caption(text: s.enginesBusy ? L("지금 받아 적는 중입니다. 변경한 엔진은 다음 녹음부터 적용됩니다.", "Transcription is in progress. The new engine will be used starting with the next recording.")
                    : s.engines.contains { $0.state == "downloading" } ? L("내려받는 동안에도 지금 엔진으로 받아 적을 수 있습니다.", "You can keep transcribing with the current engine while it downloads.")
                    : L("어느 엔진이든 녹음과 받아쓰기는 이 \("Mac") 안에서만 처리됩니다.", "Whichever engine you use, recording and transcription happen only on this \("Mac")."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 저장

private struct StorageTab: View {
    @ObservedObject var s: SettingsStore
    var body: some View {
        let _ = s.lang
        Form {
            Section {
                LabeledContent(L("기록", "Library")) {
                    if let st = s.storage {
                        Text(appLanguage.value == "ko" ? "\(st.count)개 · \(sizeText(st.bytes))" : "\(nL(st.count, "recording")) · \(sizeText(st.bytes))")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("위치", "Location")) {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 16, height: 16)
                        Text(s.storage.map { folderLabel($0.folder) } ?? "—")
                    }
                }
            } footer: {
                HStack {
                    Caption(text: L("녹음과 받아 적은 글은 ‘기록 폴더’에 자동으로 저장됩니다.", "Recordings and transcripts are saved automatically to the Library Folder."))
                    Spacer()
                    Button(L("Finder에서 보기", "Show in Finder")) { s.command("openFolder") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { s.command("storage") }
    }
}

// MARK: - 정보

private struct AboutTab: View {
    @ObservedObject var s: SettingsStore
    private let repo = "https://github.com/WeldingArc/arc-lecture-transcriber"
    var body: some View {
        let _ = s.lang
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                Text(L("Arc 강의 받아쓰기", "Arc Lecture Transcriber")).font(.title2.weight(.semibold))
                Text(L("버전", "Version") + " \(appVersion)" + (build.map { " (\($0))" } ?? "")).foregroundStyle(.secondary).textSelection(.enabled)
                Caption(text: s.engineInUse.map { L("\($0.name) · 기기 안에서 처리 · 인터넷 전송 없음", "\($0.name) · Runs on this device · Nothing sent online") }
                              ?? L("Apple 온디바이스 · 인터넷 전송 없음", "Apple on-device · Nothing sent online"))
            }
            .padding(.top, 22).padding(.bottom, 4)
            Form {
                Section {
                    LabeledContent(L("개인정보 처리방침", "Privacy Policy")) {
                        Button(L("열기", "Open")) { s.command("openLink", ["url": repo + "/blob/main/PRIVACY.md"]) }
                    }
                    LabeledContent(L("이용 안내 및 면책 고지", "Usage Notice and Disclaimer")) {
                        Button(L("열기", "Open")) { s.host?.settingsShowInMain("openLegal") }
                    }
                    LabeledContent(L("문제 신고용 로그 폴더", "Log Folder for Reporting Problems")) {
                        Button(L("열기", "Open")) { s.command("openLogs") }
                    }
                    LabeledContent(L("GitHub 페이지", "GitHub Page")) {
                        Button(L("열기", "Open")) { s.command("openLink", ["url": repo]) }
                    }
                } footer: {
                    Caption(text: L("Arc 강의 받아쓰기 · MIT 라이선스 · 개인 학습용으로 사용하십시오", "Arc Lecture Transcriber · MIT License · Use for personal study"))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - the window

/// The tabs, remembering the one last open.
private final class SettingsTabs: NSTabViewController {
    var onSelect: ((Int) -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        onSelect?(selectedTabViewItemIndex)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store = SettingsStore()
    private var window: NSWindow?
    private var tabs: SettingsTabs?
    private var appearance: NSAppearance?
    /// id, symbol, height (the window takes each tab's size), title
    private static let tabSpecs: [(id: String, symbol: String, height: CGFloat, title: () -> String)] = [
        ("general", "gearshape", 470, { L("일반", "General") }),
        ("transcription", "text.bubble", 500, { L("받아쓰기", "Transcription") }),
        ("speech", "waveform", 380, { L("음성 인식", "Speech Recognition") }),
        ("storage", "internaldrive", 200, { L("저장", "Storage") }),
        ("about", "info.circle", 430, { L("정보", "About") }),
    ]
    static let width: CGFloat = 600

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens the window (or brings it forward), at a tab: "general", "transcription", "speech", "storage", "about".
    func show(tab: String? = nil) {
        if window == nil { build() }
        if let tab, let i = Self.tabSpecs.firstIndex(where: { $0.id == tab }) { tabs?.selectedTabViewItemIndex = i }
        store.command("storage")
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build(at index: Int? = nil) {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for spec in Self.tabSpecs {
            let view: AnyView
            switch spec.id {
            case "general": view = AnyView(GeneralTab(s: store))
            case "transcription": view = AnyView(TranscriptionTab(s: store))
            case "speech": view = AnyView(SpeechTab(s: store))
            case "storage": view = AnyView(StorageTab(s: store))
            default: view = AnyView(AboutTab(s: store))
            }
            // as tall as its content in the app's language (German runs long), within reason: a taller tab scrolls
            let host = NSHostingController(rootView: view.frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
                                                         .frame(minHeight: 160, maxHeight: 720))
            host.sizingOptions = [.preferredContentSize]               // the window takes each tab's size
            host.title = spec.title()                                  // …and its name as the window's title
            let item = NSTabViewItem(viewController: host)
            item.identifier = spec.id
            item.label = spec.title()
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: "settingsTab")
        tabs.selectedTabViewItemIndex = index ?? Self.tabSpecs.firstIndex { $0.id == saved } ?? 0
        tabs.onSelect = { i in UserDefaults.standard.set(Self.tabSpecs[i].id, forKey: "settingsTab") }
        let win = NSWindow(contentViewController: tabs)
        win.styleMask = [.titled, .closable]
        win.toolbarStyle = .preference
        win.collectionBehavior = [.fullScreenAuxiliary]                // opens over the main window in full screen
        win.isReleasedWhenClosed = false
        win.appearance = appearance
        win.delegate = self
        if index == nil {
            win.center()
            win.setFrameAutosaveName("SettingsWindow")
        }
        self.window = win
        self.tabs = tabs
    }

    /// The app's language changed: the window again in it (made anew where it was, at the same tab) — once the event that
    /// changed it is over: the menu that chose it lives in the window being replaced.
    func languageChanged() {
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        store.lang = appLanguage.value
        store.chosen = AppLanguage.chosen != nil
        guard let old = window, let tabs else { return }
        let visible = old.isVisible, origin = old.frame.origin, height = old.frame.height, tab = tabs.selectedTabViewItemIndex
        old.delegate = nil
        old.orderOut(nil)
        window = nil
        self.tabs = nil
        build(at: tab)
        guard let win = window else { return }
        win.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + height))   // the top stays put
        if visible { win.makeKeyAndOrderFront(nil) }
    }

    /// 설정 › 테마: the same look as the main window (nil: follows macOS).
    func applyAppearance(_ a: NSAppearance?) {
        appearance = a
        window?.appearance = a
    }
}
#endif
