// The one way from the page to native code: the message handler named "native".
// The page is treated as untrusted input. Commands take identifiers and plain values, never
// file paths. Both flavors answer log and device.info. The device test commands (notifications,
// audio, motion, web content termination counter) are compiled into the dev flavor only, the
// release flavor answers them with "unknown command".
import UIKit
import WebKit
import os
#if DEV_FLAVOR
import UserNotifications
import AVFAudio
import CoreMotion
#endif

@MainActor
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    // Incremented by WebViewController each time the web content process dies.
    static let terminationCountKey = "webContentTerminations"

    weak var webView: WKWebView?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "shell", category: "spike")
    #if DEV_FLAVOR
    private var player: AVAudioPlayer?
    private let motion = CMMotionManager()
    private var lastSample: TimeInterval = 0
    #endif

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return (nil, "malformed message: expected {cmd: string, ...}")
        }
        switch cmd {
        case "log":
            guard let line = body["line"] as? String, line.count <= 4000 else {
                return (nil, "log needs line: a string of at most 4000 characters")
            }
            logger.log("\(line, privacy: .public)")
            return (["ok": true], nil)
        case "device.info":
            let info: [String: Any] = [
                "flavor": SoakEntry.flavor,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                "os": UIDevice.current.systemVersion,
                "tz": TimeZone.current.identifier,
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "secureContextHint": NSNull(),
            ]
            return (info, nil)
        #if DEV_FLAVOR
        case "notify.request": return await notifyRequest()
        case "notify.schedule": return await notifySchedule(body)
        case "notify.pending": return await notifyPending()
        case "audio.play": return audioPlay(body)
        case "audio.stop": return audioStop()
        case "motion.start": return motionStart(body)
        case "motion.stop":
            motion.stopDeviceMotionUpdates()
            return (["ok": true], nil)
        case "counter.get":
            return (["count": UserDefaults.standard.integer(forKey: Self.terminationCountKey)], nil)
        #endif
        default:
            return (nil, "unknown command")
        }
    }

    #if DEV_FLAVOR
    private func notifyRequest() async -> (Any?, String?) {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return (["granted": granted], nil)
        } catch {
            return (nil, "notify.request: \(error.localizedDescription)")
        }
    }

    // Wall-clock components (year to minute) in the current calendar with timeZone left nil,
    // to see whether the trigger floats with a later time zone change.
    private func notifySchedule(_ body: [String: Any]) async -> (Any?, String?) {
        guard let offsets = body["offsets"] as? [Int], (1...20).contains(offsets.count),
              offsets.allSatisfy({ (1...20160).contains($0) }) else {
            return (nil, "notify.schedule needs offsets: 1 to 20 whole minutes, each 1 to 20160")
        }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var ids: [String] = []
        for offset in offsets {
            var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                        from: now.addingTimeInterval(TimeInterval(offset * 60)))
            parts.timeZone = nil
            let content = UNMutableNotificationContent()
            content.body = "Testbenachrichtigung"
            let id = "test-\(offset)-\(UUID().uuidString.prefix(8))"
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                return (nil, "notify.schedule: \(error.localizedDescription)")
            }
            ids.append(id)
        }
        return (ids, nil)
    }

    // Reads only. Nothing is rescheduled, so a later read shows what iOS itself kept.
    private func notifyPending() async -> (Any?, String?) {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let list: [[String: Any]] = requests.map { request in
            var item: [String: Any] = ["id": request.identifier, "nextTriggerDate": NSNull()]
            if let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                item["nextTriggerDate"] = SoakEntry.iso(next)
            }
            return item
        }
        return (list, nil)
    }

    // The only file access in the bridge: www/<id>.m4a inside the bundle, id checked against
    // ^[a-z0-9-]{1,32}$ (written with \A and \z so a trailing newline cannot slip through).
    private func audioPlay(_ body: [String: Any]) -> (Any?, String?) {
        guard let id = body["id"] as? String,
              id.range(of: "\\A[a-z0-9-]{1,32}\\z", options: .regularExpression) != nil else {
            return (nil, "audio.play needs id matching ^[a-z0-9-]{1,32}$")
        }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("www", isDirectory: true)
            .appendingPathComponent(id + ".m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            player?.stop()
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.play() else { return (nil, "audio.play: player refused to start") }
            self.player = player
            return (["ok": true, "duration": player.duration], nil)
        } catch {
            return (nil, "audio.play: \(error.localizedDescription)")
        }
    }

    private func audioStop() -> (Any?, String?) {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (["ok": true], nil)
    }

    // Samples go to window.__shell.motion, throttled here to the requested rate (cap 60 Hz).
    private func motionStart(_ body: [String: Any]) -> (Any?, String?) {
        guard let requested = body["hz"] as? Double, requested > 0 else {
            return (nil, "motion.start needs hz: a number above 0")
        }
        guard motion.isDeviceMotionAvailable else { return (nil, "motion.start: device motion not available") }
        let hz = min(requested, 60)
        let interval = 1 / hz
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let magnetic = available.contains(.xMagneticNorthZVertical)
        let frame: CMAttitudeReferenceFrame = magnetic ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
        let frameName = magnetic ? "xMagneticNorthZVertical" : "xArbitraryCorrectedZVertical"
        motion.stopDeviceMotionUpdates()
        motion.deviceMotionUpdateInterval = interval
        lastSample = 0
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            if data.timestamp - self.lastSample < interval * 0.9 { return }
            self.lastSample = data.timestamp
            let q = data.attitude.quaternion
            let sample: [String: Any] = ["q": [q.x, q.y, q.z, q.w], "heading": data.heading,
                                         "frame": frameName, "t": data.timestamp]
            guard JSONSerialization.isValidJSONObject(sample),
                  let json = try? JSONSerialization.data(withJSONObject: sample),
                  let text = String(data: json, encoding: .utf8) else { return }
            self.webView?.evaluateJavaScript(
                "window.__shell && window.__shell.motion && window.__shell.motion(\(text))",
                completionHandler: nil)
        }
        return (["ok": true, "frame": frameName, "frames": Self.frameNames(available), "hz": hz], nil)
    }

    private static func frameNames(_ set: CMAttitudeReferenceFrame) -> [String] {
        var names: [String] = []
        if set.contains(.xArbitraryZVertical) { names.append("xArbitraryZVertical") }
        if set.contains(.xArbitraryCorrectedZVertical) { names.append("xArbitraryCorrectedZVertical") }
        if set.contains(.xMagneticNorthZVertical) { names.append("xMagneticNorthZVertical") }
        if set.contains(.xTrueNorthZVertical) { names.append("xTrueNorthZVertical") }
        return names
    }
    #endif
}
