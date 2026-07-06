import Foundation
import UserNotifications

/// Polls Google Calendar for upcoming events that carry a Google Meet link and
/// fires an actionable notification shortly before they start.
/// Credentials: ~/.config/calldrop/google.json {client_id, client_secret, refresh_token}
/// (created by transcribe-pipeline/google_calendar_auth.py). Absent file = feature off.
@MainActor
final class CalendarWatcher: ObservableObject {
    static let shared = CalendarWatcher()

    @Published var nextCall: String?

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var notified = Set<String>()
    private var timer: Timer?

    private var credsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.config/calldrop/google.json")
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await CalendarWatcher.shared.poll() }
        }
        Task { await poll() }
    }

    private func loadCreds() -> [String: String]? {
        guard let data = try? Data(contentsOf: credsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return json
    }

    private func refreshTokenIfNeeded() async -> Bool {
        if accessToken != nil, tokenExpiry > Date().addingTimeInterval(60) { return true }
        guard let creds = loadCreds(),
              let id = creds["client_id"], let secret = creds["client_secret"],
              let refresh = creds["refresh_token"] else { return false }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "client_id=\(id)&client_secret=\(secret)&refresh_token=\(refresh)&grant_type=refresh_token"
            .data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { return false }
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600))
        return true
    }

    private func poll() async {
        guard await refreshTokenIfNeeded(), let token = accessToken else {
            nextCall = nil
            return
        }
        let iso = ISO8601DateFormatter()
        let now = iso.string(from: Date())
        let horizon = iso.string(from: Date().addingTimeInterval(30 * 60))
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: now),
            .init(name: "timeMax", value: horizon),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "10"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return }

        var upcoming: (id: String, title: String, start: Date)?
        for ev in items {
            let hasMeet = ev["hangoutLink"] != nil
                || (ev["location"] as? String)?.contains("meet.google.com") == true
                || (ev["description"] as? String)?.contains("meet.google.com") == true
            guard hasMeet,
                  let id = ev["id"] as? String,
                  let startObj = ev["start"] as? [String: Any],
                  let startStr = startObj["dateTime"] as? String,
                  let start = parseRFC3339(startStr) else { continue }
            let title = ev["summary"] as? String ?? "Meeting"
            if upcoming == nil { upcoming = (id, title, start) }
        }

        guard let call = upcoming else {
            nextCall = nil
            return
        }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        nextCall = "Next: \(call.title) @ \(fmt.string(from: call.start))"

        let secondsAway = call.start.timeIntervalSinceNow
        if secondsAway < 90, !notified.contains(call.id) {
            notified.insert(call.id)
            let content = UNMutableNotificationContent()
            content.title = "Call starting: \(call.title)"
            content.body = "Click to record and transcribe this call."
            content.categoryIdentifier = "UPCOMING_CALL"
            content.userInfo = ["eventTitle": call.title]
            content.sound = .default
            let request = UNNotificationRequest(identifier: "call-\(call.id)",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
