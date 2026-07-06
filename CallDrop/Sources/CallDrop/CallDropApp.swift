import SwiftUI
import AppKit
import Combine
import UserNotifications

let INBOX = URL(fileURLWithPath: NSHomeDirectory() + "/Vibecoding/Transcripts/inbox")

@main
struct CallDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    // A floating non-activating panel instead of MenuBarExtra's popover: the
    // popover auto-dismisses when Finder gets focus, which makes dragging a
    // file into it impossible. The panel stays up until explicitly closed.
    private var panel: NSPanel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle",
                                   accessibilityDescription: "CallDrop")
            button.action = #selector(togglePanel)
            button.target = self
        }

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "CallDrop"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: DropView())

        Recorder.shared.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                let name = recording ? "record.circle.fill" : "waveform.circle"
                let img = NSImage(systemSymbolName: name, accessibilityDescription: "CallDrop")
                if recording {
                    self?.statusItem.button?.image = img?.withSymbolConfiguration(
                        .init(paletteColors: [.systemRed]))
                } else {
                    self?.statusItem.button?.image = img
                }
            }
            .store(in: &cancellables)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "RECORD", title: "Record call",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: "UPCOMING_CALL",
                                              actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        CalendarWatcher.shared.start()
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionUnderStatusItem()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func positionUnderStatusItem() {
        guard let buttonWindow = statusItem.button?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.frame
        let size = panel.frame.size
        let x = min(anchor.midX - size.width / 2,
                    screen.visibleFrame.maxX - size.width - 8)
        let y = anchor.minY - 6
        panel.setFrameTopLeftPoint(NSPoint(x: max(x, screen.visibleFrame.minX + 8), y: y))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "RECORD" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let title = response.notification.request.content.userInfo["eventTitle"] as? String
            Task { @MainActor in
                Recorder.shared.pendingTitle = title
                try? await Recorder.shared.start()
            }
        }
        completionHandler()
    }
}
