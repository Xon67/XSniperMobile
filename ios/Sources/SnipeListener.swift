import Foundation
import UIKit
import UserNotifications
import AVFoundation

/// Keeps a live connection to the PC while the app is in the background (a silent audio loop stops iOS from
/// freezing the app) and turns every snipe into a real notification with a sound and a buzz.
final class SnipeListener: NSObject, URLSessionDataDelegate, UNUserNotificationCenterDelegate {
    static let shared = SnipeListener()

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var eventURL: URL?
    private var buffer = Data()
    private var lastID = 0
    private var retry = 0
    private var seen = Set<Int>()
    private var player: AVAudioPlayer?
    private var running = false

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45          // the PC sends a ping every 15s
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 365
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue.main)
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: start / stop
    func start(link: String) {
        guard let u = URL(string: link),
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let t = comps.queryItems?.first(where: { $0.name == "t" })?.value, !t.isEmpty else { stop(); return }
        var base = URLComponents()
        base.scheme = u.scheme; base.host = u.host; base.port = u.port; base.path = "/events"
        base.queryItems = [URLQueryItem(name: "t", value: t)]
        guard let ev = base.url else { return }
        if running && ev == eventURL { ensure(); return }
        stop()
        eventURL = ev; running = true; lastID = 0; retry = 0; seen.removeAll()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        startAudio()
        connect()
    }

    func stop() {
        running = false
        let t = task; task = nil; t?.cancel()
        player?.stop(); player = nil
    }

    /// Called whenever the app comes back to the front: restart anything iOS stopped.
    func ensure() {
        guard running else { return }
        if player?.isPlaying != true { startAudio() }
        if task == nil || task?.state != .running { connect() }
    }

    private func connect() {
        guard running, let url = eventURL else { return }
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if lastID > 0 { req.setValue(String(lastID), forHTTPHeaderField: "Last-Event-ID") }
        buffer.removeAll()
        let t = session.dataTask(with: req)
        task = t
        t.resume()
    }

    // MARK: the live stream
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse, h.statusCode == 200 { retry = 0; completionHandler(.allow) }
        else { completionHandler(.cancel) }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let sep = Data("\n\n".utf8)
        while let r = buffer.range(of: sep) {
            let block = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            handle(String(decoding: block, as: UTF8.self))
        }
    }

    func urlSession(_ s: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard running, finished === task else { return }
        task = nil
        retry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + min(8, Double(retry))) { [weak self] in self?.connect() }
    }

    private func handle(_ block: String) {
        var payload = ""
        for line in block.split(separator: "\n") {
            if line.hasPrefix("data:") { payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        }
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
        let id = (obj["id"] as? NSNumber)?.intValue ?? 0
        if id > 0 { if seen.contains(id) { return }; seen.insert(id); lastID = max(lastID, id) }
        let age = (obj["age"] as? NSNumber)?.doubleValue ?? 0
        if age > 90 { return }                       // old replay from before we connected

        let rawTitle = (obj["title"] as? String) ?? ""
        let isTest = rawTitle.lowercased().contains("test")
        var name = rawTitle.replacingOccurrences(of: "^snipe:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Snipe" }
        if isTest { name = "Test alert" } else { name = name.capitalized }
        let src = ((obj["body"] as? String) ?? "")
            .replacingOccurrences(of: "\\s*-\\s*tap to join\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        let link = (obj["link"] as? String) ?? ""

        let c = UNMutableNotificationContent()
        c.title = isTest ? "XSniper test" : "Sniped: " + name
        c.body = (src.isEmpty ? "" : src + " \u{00B7} ") + "tap to join"
        c.sound = .default
        c.threadIdentifier = "snipes"
        c.userInfo = ["link": link]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: notifications
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        if let s = r.notification.request.content.userInfo["link"] as? String, let u = URL(string: s) {
            UIApplication.shared.open(u)
        }
        h()
    }

    // MARK: silent audio keep-alive
    private func startAudio() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: SnipeListener.silence())
                player?.numberOfLoops = -1
                player?.prepareToPlay()
            }
            player?.play()
        } catch {}
    }

    @objc private func audioInterrupted(_ n: Notification) {
        guard running, let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: v) == .ended else { return }
        startAudio()
    }

    /// Two seconds of inaudible audio (tiny +-2 samples) as an in-memory WAV.
    private static func silence() -> Data {
        let rate = 8000, n = rate * 2, bytes = n * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        for i in 0..<n { u16(i % 2 == 0 ? 2 : 0xFFFE) }
        return d
    }
}
