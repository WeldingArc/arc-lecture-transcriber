// Mac: the page's pop-up menus as macOS menus — the start screen's globe (the app's language), 다른 언어 (the lecture
// language) and a recording's ⋯ in 기록. The page says what to list and where its button is; the choice goes back to
// the page, which acts on it as it did with its own menu (the same checks, questions and messages).

#if os(macOS)
import AppKit
import WebKit

@MainActor
final class PopUpMenus: NSObject {
    weak var web: WKWebView?
    /// The answer for the page: {ev: "menuPick", kind, value (null: closed without a choice), id}.
    var reply: (([String: Any]) -> Void)?
    private var chosen: Any?
    private var open = false
    private var current: NSMenu?

    /// body: kind; items [{title, value, on, disabled, symbol} | {type: "separator"} | {type: "header", title}];
    /// x, y, w, h: the button's box in the page (top-left origin); at: [x, y] for a right-click; up: opens upward.
    func show(_ body: [String: Any]) {
        guard let web, !open else { return }
        let menu = build(body["items"] as? [[String: Any]] ?? [])
        guard !menu.items.isEmpty else { return }
        func n(_ k: String) -> CGFloat { CGFloat((body[k] as? NSNumber)?.doubleValue ?? 0) }
        // the page's points, top-left origin → the web view's own coordinates
        func point(_ x: CGFloat, _ yTop: CGFloat) -> NSPoint { NSPoint(x: x, y: web.isFlipped ? yTop : web.bounds.height - yTop) }
        let at: NSPoint, positioning: NSMenuItem?
        if let p = body["at"] as? [NSNumber], p.count == 2 {                          // right-click: at the pointer
            at = point(CGFloat(p[0].doubleValue), CGFloat(p[1].doubleValue)); positioning = nil
        } else if body["up"] as? Bool == true {                                      // the bottom row: above the button
            at = point(n("x"), n("y") - 4 - menu.size.height); positioning = nil      // (macOS keeps it on screen)
        } else {                                                                     // below the button, its left edge
            at = point(n("x"), n("y") + n("h") + 4); positioning = nil
        }
        menu.appearance = web.window?.appearance
        chosen = nil
        open = true
        current = menu
        let kind = body["kind"] as? String ?? "", id = body["id"] ?? NSNull()
        if let spec = env["LECTURE_TEST_MENU"], let colon = spec.firstIndex(of: ":"), let t = Double(spec[..<colon]) {
            let want = String(spec[spec.index(after: colon)...])                     // tests: "2.5:en" — after 2.5 s, what the
            let timer = Timer(timeInterval: t, repeats: false) { [weak self] _ in     // menu lists (app.log), then that choice
                MainActor.assumeIsolated {                                           // ("-": closed without one)
                    guard let self, let menu = self.current else { return }
                    func list(_ m: NSMenu) -> String {
                        m.items.map { i in
                            i.isSeparatorItem ? "—" : i.isSectionHeader ? "[\(i.title)]"
                                : (i.state == .on ? "✓" : "") + i.title + (i.isEnabled ? "" : " (off)") + (i.image != nil ? " (icon)" : "")
                                  + (i.submenu.map { " ▸ {" + list($0) + "}" } ?? "")
                        }.joined(separator: " | ")
                    }
                    log("test menu \(kind): " + list(menu))
                    let all = menu.items + menu.items.compactMap(\.submenu).flatMap(\.items)
                    if let item = all.first(where: { ($0.representedObject as? String) == want }) { self.chosen = item.representedObject }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        DispatchQueue.main.async { [weak self] in                                    // not inside the page's message
            guard let self, let web = self.web else { return }
            menu.popUp(positioning: positioning, at: at, in: web)
            self.open = false
            self.current = nil
            let value = self.chosen
            self.chosen = nil
            self.reply?(["ev": "menuPick", "kind": kind, "value": value ?? NSNull(), "id": id])
        }
    }

    /// items [{title, value, on, disabled, symbol, submenu: [items]} | {type: "separator"} | {type: "header", title}]
    private func build(_ items: [[String: Any]]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for it in items {
            switch it["type"] as? String {
            case "separator": menu.addItem(.separator())
            case "header": menu.addItem(.sectionHeader(title: it["title"] as? String ?? ""))
            default:
                let item = NSMenuItem(title: it["title"] as? String ?? "", action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = it["value"]
                item.state = it["on"] as? Bool == true ? .on : .off
                item.isEnabled = it["disabled"] as? Bool != true
                if let symbol = it["symbol"] as? String { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if let sub = it["submenu"] as? [[String: Any]] { item.action = nil; item.submenu = build(sub) }
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func pick(_ item: NSMenuItem) { chosen = item.representedObject }
}
#endif
