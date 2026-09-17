// Copyright (c) 2026 Dr Daniel Mompel Riera
// Licensed under the GNU Affero General Public License v3.0.
// Free to use and change; if you pass on a changed version, or let anyone
// use it over a network, you must publish your source under the same licence.
// Commercial use needs my permission: dmompelriera@nlcsjeju.kr
// A single clean window showing one page - no tab bar, no address bar, no browser.
//
//   app-window-native <url> [width] [height]
//
// This exists because a Chromium --app window comes with a second Dock icon (the
// separate --user-data-dir instance registers as its own application), and clicking
// that icon makes Chrome open an empty chrome://newtab window. A window of our own
// answers a Dock click by coming to the front, which is what you actually want.
//
// It has to carry its own weight on the things a browser gives a page for free:
// alert/confirm/prompt, file pickers, downloads and printing are all implemented below,
// because WKWebView silently does nothing for any of them.

import Cocoa
import WebKit

// ---------------------------------------------------------------- arguments
let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, !first.isEmpty else {
    FileHandle.standardError.write("usage: app-window-native <url> [width] [height]\n".data(using: .utf8)!)
    exit(2)
}
let startURL: URL = URL(string: first) ?? URL(fileURLWithPath: first)
let startW = CGFloat(Double(args.count > 1 ? args[1] : "") ?? 1180)
let startH = CGFloat(Double(args.count > 2 ? args[2] : "") ?? 820)

// ---------------------------------------------------------------- one window, only ever
// Opening the app again must not stack up windows or Dock icons. If we are already
// running, hand the URL to that instance and get out of the way.
let bundleID = Bundle.main.bundleIdentifier ?? "uk.dmr.appwindow"
let openNote = Notification.Name(bundleID + ".open")
let mePID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != mePID && !$0.isTerminated }
if let running = others.first {
    DistributedNotificationCenter.default().postNotificationName(
        openNote, object: startURL.absoluteString, userInfo: nil, deliverImmediately: true)
    running.activate(options: [])
    exit(0)
}

// ---------------------------------------------------------------- the app
final class Controller: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate,
                        WKDownloadDelegate, WKScriptMessageHandler, NSWindowDelegate {

    var window: NSWindow!
    var web: WKWebView!
    private var titleObs: NSKeyValueObservation?
    private var savePanelURL: URL?

    // Give the page a real window.print() and window.close(), neither of which
    // WKWebView provides. window.close() is the sharper one: WebKit only honours it on
    // a view JavaScript itself opened, so on a page we loaded it does nothing at all -
    // silently. Every "Got it" / "Done" button in these pages is a window.close(), and
    // every one of them was dead. Overriding it here fixes them all without touching a
    // line of HTML, and leaves real browsers to their own native behaviour.
    private let pageShim = """
    (function(){
      window.print = function(){
        try { window.webkit.messageHandlers.appwindow.postMessage("print"); } catch (e) {}
      };
      window.close = function(){
        try { window.webkit.messageHandlers.appwindow.postMessage("close"); } catch (e) {}
      };
    })();
    """

    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: pageShim,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        ucc.add(self, name: "appwindow")
        cfg.userContentController = ucc
        // The pages talk to a helper on 127.0.0.1 and load their own file:// assets.
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: startW, height: startH), configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        if web.responds(to: Selector(("setAllowsLinkPreview:"))) { web.allowsLinkPreview = false }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: startW, height: startH),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = web
        window.delegate = self
        window.title = displayName()
        window.tabbingMode = .disallowed          // never merge into a tab bar
        window.center()
        window.setFrameAutosaveName("AppWindowFrame")
        window.makeKeyAndOrderFront(nil)

        // Follow the page title, the way an --app window does.
        titleObs = web.observe(\.title, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            if let t = self.web.title, !t.isEmpty { self.window.title = t }
        }

        buildMenu()
        load(startURL)
        NSApp.activate(ignoringOtherApps: true)

        // A second launch hands us its URL rather than opening another window.
        DistributedNotificationCenter.default().addObserver(
            forName: openNote, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let s = note.object as? String, let u = URL(string: s),
               u.absoluteString != self.web.url?.absoluteString {
                self.load(u)
            }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func displayName() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }

    private func load(_ url: URL) {
        if url.isFileURL {
            // Read access has to cover more than the containing folder. The birthday page
            // is generated under Application Support and its "See the whole year" link
            // points into the app folder; scoped to one directory, WebKit refuses that
            // navigation and the link does nothing. These are our own local pages.
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            web.load(URLRequest(url: url))
        }
    }

    // ------------------------------------------------------------ lifecycle
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // A click on the Dock icon brings this window forward. It must never create a
    // second, empty window - that was the whole bug.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // ------------------------------------------------------------ JS dialogs
    private func alertPanel(_ text: String, style: NSAlert.Style = .informational) -> NSAlert {
        let a = NSAlert()
        a.messageText = displayName()
        a.informativeText = text
        a.alertStyle = style
        return a
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
        let a = alertPanel(m); a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in done() }
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (Bool) -> Void) {
        let a = alertPanel(m, style: .warning)
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in done(r == .alertFirstButtonReturn) }
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String,
                 defaultText: String?, initiatedByFrame f: WKFrameInfo,
                 completionHandler done: @escaping (String?) -> Void) {
        let a = alertPanel(p)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            done(r == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // <input type="file">
    func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.beginSheetModal(for: window) { r in done(r == .OK ? p.urls : nil) }
    }

    // target=_blank and window.open() stay in this one window.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { w.load(URLRequest(url: u)) }
        return nil
    }

    // ------------------------------------------------------------ downloads
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler done: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.shouldPerformDownload { done(.download, preferences) }
        else { done(.allow, preferences) }
    }

    func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler done: @escaping (WKNavigationResponsePolicy) -> Void) {
        done(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ w: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) { download.delegate = self }

    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) { download.delegate = self }

    func download(_ d: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler done: @escaping (URL?) -> Void) {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedFilename
        p.canCreateDirectories = true
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let u = p.url else { done(nil); return }
            try? FileManager.default.removeItem(at: u)   // the panel already confirmed a replace
            done(u)
        }
    }

    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        let a = alertPanel("The download did not finish.\n\n\(e.localizedDescription)", style: .warning)
        a.addButton(withTitle: "OK"); a.beginSheetModal(for: window) { _ in }
    }

    // ------------------------------------------------------------ printing
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        switch m.body as? String {
        case "print": doPrint()
        case "close": window.performClose(nil)
        default: break
        }
    }

    // For a view JavaScript really did open, WebKit calls this instead.
    func webViewDidClose(_ webView: WKWebView) { window.performClose(nil) }

    private func doPrint() {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let op = web.printOperation(with: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // plan.html rearranges itself for printing and puts itself back on afterprint.
        web.evaluateJavaScript("window.dispatchEvent(new Event('afterprint'));", completionHandler: nil)
    }

    @objc func printPage(_ sender: Any?) { doPrint() }

    // ------------------------------------------------------------ menu bar
    private func buildMenu() {
        let name = displayName()
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Print…", action: #selector(printPage(_:)), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    @objc func reloadPage(_ s: Any?) { web.reload() }
    @objc func zoomReset(_ s: Any?)  { web.pageZoom = 1.0 }
    @objc func zoomIn(_ s: Any?)     { web.pageZoom = min(web.pageZoom + 0.1, 3.0) }
    @objc func zoomOut(_ s: Any?)    { web.pageZoom = max(web.pageZoom - 0.1, 0.4) }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)     // one Dock icon: this app, with this app's name
app.run()
