import SwiftUI
import AppKit

/// Plain AppKit bootstrap rather than the `@main` App protocol: this lets us build
/// with CommandLineTools' `swiftc` and a hand-assembled bundle, with no Xcode project
/// and no reliance on SwiftUI's app lifecycle machinery.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    /// A hand-assembled app has no `MainMenu.xib`, so `NSApp.mainMenu` is nil and
    /// every standard key equivalent — including ⌘Q — is dead: AppKit finds no menu
    /// item carrying it and just beeps. Install the minimum menu that makes the
    /// platform's own shortcuts work.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // The first submenu is the application menu regardless of its title; macOS
        // displays the process name next to it.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "About Stablecoin Yield",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        // target: nil → routed through the responder chain to NSApplication, which
        // handles termination. Without this item ⌘Q has nothing to fire.
        appMenu.addItem(
            withTitle: "Quit Stablecoin Yield",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // An Edit menu is what makes ⌘C/⌘V/⌘A reach the focused text field.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// Exposed so `--dumpmenu` can build the menu without opening a window.
    func testInstallMainMenu() { installMainMenu() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let content = ContentView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stablecoin Yield — verified against the live site"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Headless self-test

private func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

/// `StablecoinYield --selftest [n]` runs the whole fetch → crawl → cross-check
/// pipeline in the terminal. This is how the verification can be inspected without
/// a GUI, and the honest way to check the app is really confirming anything.
private func runSelfTest(_ n: Int) {
    let sem = DispatchSemaphore(value: 0)

    Task {
        do {
            print("Fetching Ethereum stablecoin candidates from Beefy…")
            let opps = try await BeefySource.fetchEthereumStablecoins()
            print("Found \(opps.count) candidates. Verifying top \(n) against the live site.\n")

            print(pad("VAULT", 30) + pad("PLATFORM", 11) + pad("TVL", 10, right: true)
                  + pad("API", 9, right: true) + pad("SITE", 9, right: true)
                  + "  " + pad("WARNINGS", 32) + "VERDICT")
            print(String(repeating: "-", count: 125))

            let verifier = APYVerifier()
            var verified = 0, mismatched = 0, unverified = 0

            for opp in opps.prefix(n) {
                let state = await verifier.verify(
                    id: opp.id,
                    pageURL: opp.pageURL,
                    apiPercent: opp.apiAPYPercent
                )
                let site: String
                let verdict: String
                switch state {
                case .verified(_, let c):
                    site = Fmt.apy(c); verdict = "VERIFIED — site and API agree"
                    verified += 1
                case .mismatch(let a, let c):
                    site = Fmt.apy(c); verdict = "MISMATCH — API says \(Fmt.apy(a))"
                    mismatched += 1
                case .unverified(let r):
                    site = "—"; verdict = "UNVERIFIED — \(r)"
                    unverified += 1
                default:
                    site = "—"; verdict = "\(state)"
                }
                var warnings = opp.risk.labels
                if opp.isThinlyTraded { warnings.append("tiny pool") }

                print(pad(opp.name, 30) + pad(opp.platform, 11)
                      + pad(Fmt.usd(opp.tvlUSD), 10, right: true)
                      + pad(Fmt.apy(opp.apiAPYPercent), 9, right: true)
                      + pad(site, 9, right: true)
                      + "  " + pad(warnings.isEmpty ? "—" : warnings.joined(separator: ","), 32)
                      + verdict)
            }

            print("\nSummary: \(verified) verified, \(mismatched) mismatched, \(unverified) unverified")
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
        sem.signal()
    }

    sem.wait()
    exit(0)
}

/// `StablecoinYield --dumpmenu` prints the installed menu tree with key equivalents.
/// ⌘Q cannot be tested by pressing it from a script here (no assistive access), so
/// this is how the binding is checked: the item must exist, off "q", with the
/// terminate action. Exits before the run loop.
if CommandLine.arguments.contains("--dumpmenu") {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.testInstallMainMenu()
    func walk(_ menu: NSMenu, _ depth: Int) {
        for item in menu.items {
            let indent = String(repeating: "  ", count: depth)
            if item.isSeparatorItem {
                print(indent + "---")
                continue
            }
            let key = item.keyEquivalent.isEmpty
                ? ""
                : "  ⌘\(item.keyEquivalent)"
            let action = item.action.map { NSStringFromSelector($0) } ?? "(no action)"
            let target = item.target == nil ? "responder-chain" : "explicit"
            print("\(indent)\(item.title.isEmpty ? "(root)" : item.title)\(key)  → \(action) [\(target)]")
            if let sub = item.submenu { walk(sub, depth + 1) }
        }
    }
    if let m = NSApp.mainMenu {
        walk(m, 0)
    } else {
        print("ERROR: NSApp.mainMenu is nil")
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let n = (i + 1 < CommandLine.arguments.count) ? (Int(CommandLine.arguments[i + 1]) ?? 6) : 6
    runSelfTest(n)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()