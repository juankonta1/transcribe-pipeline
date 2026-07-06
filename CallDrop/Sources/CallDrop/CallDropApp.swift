import SwiftUI
import UserNotifications

let INBOX = URL(fileURLWithPath: NSHomeDirectory() + "/Vibecoding/Transcripts/inbox")

@main
struct CallDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recorder = Recorder.shared
    @StateObject private var calendar = CalendarWatcher.shared

    var body: some Scene {
        MenuBarExtra {
            DropView()
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(recorder.isRecording ? .multicolor : .monochrome)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
