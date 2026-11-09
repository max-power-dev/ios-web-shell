// A native launch log for long offline runs. Every cold launch, every resume and every
// one-tap marker becomes one entry in Application Support/soak/log.json, and the same entry
// goes to the unified log (category "soak") so a USB syslog capture holds it too.
// The app cannot record a launch that iOS refused, so a missing day here is itself the signal.
import UIKit
import Network
import os

struct SoakEntry: Codable {
    let t: String          // ISO 8601 with offset
    let kind: String       // launch, resume, marker
    let marker: String?
    let bootTime: String   // ISO 8601, rounded to the second
    let tz: String
    let lowPower: Bool
    let path: String       // satisfied, unsatisfied, requiresConnection, unknown
    let flavor: String
    let build: String

    static func make(kind: String, marker: String? = nil) -> SoakEntry {
        let now = Date()
        return SoakEntry(t: iso(now),
                         kind: kind,
                         marker: marker,
                         bootTime: iso(bootDate(now: now)),
                         tz: TimeZone.current.identifier,
                         lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                         path: currentPathStatus(),
                         flavor: flavor,
                         build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
    }

    #if DEV_FLAVOR
    static let flavor = "dev"
    #else
    static let flavor = "release"
    #endif

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // kern.boottime is the wall-clock boot moment. systemUptime stops while the device sleeps,
    // so now - systemUptime drifts forward every night and would look like a reboot. It is
    // only the fallback if the sysctl read fails.
    static func bootDate(now: Date) -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 {
            return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
        }
        let fallback = now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        return Date(timeIntervalSince1970: fallback.timeIntervalSince1970.rounded())
    }

    // The first NWPathMonitor update, no network request. At most one second, else unknown.
    static func currentPathStatus() -> String {
        final class Result: @unchecked Sendable {
            let lock = NSLock()
            var status = "unknown"
        }
        let monitor = NWPathMonitor()
        let done = DispatchSemaphore(value: 0)
        let result = Result()
        monitor.pathUpdateHandler = { path in
            let name: String
            switch path.status {
            case .satisfied: name = "satisfied"
            case .unsatisfied: name = "unsatisfied"
            case .requiresConnection: name = "requiresConnection"
            @unknown default: name = "unknown"
            }
            result.lock.lock(); result.status = name; result.lock.unlock()
            done.signal()
        }
        monitor.start(queue: DispatchQueue(label: "soak.path"))
        _ = done.wait(timeout: .now() + 1)
        monitor.cancel()
        result.lock.lock(); defer { result.lock.unlock() }
        return result.status
    }
}

final class SoakLogStore {
    static let didChange = Notification.Name("SoakLogStore.didChange")

    private(set) var entries: [SoakEntry] = []
    private let fileURL: URL
    private let backupURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "shell", category: "soak")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("soak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("log.json")
        backupURL = dir.appendingPathComponent("log.json.bak")
        entries = Self.load(fileURL) ?? Self.load(backupURL) ?? []
    }

    private static func load(_ url: URL) -> [SoakEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SoakEntry].self, from: data)
    }

    func append(_ entry: SoakEntry) {
        entries.append(entry)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("soak write failed: \(error.localizedDescription, privacy: .public)")
        }
        if let line = try? encoder.encode(entry), let text = String(data: line, encoding: .utf8) {
            logger.log("\(text, privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

final class SoakLogViewController: UITableViewController {
    static let markers = ["Flugmodus-Tag", "Sperre aus", "Sperre an", "Neustart offline", "Zwangsbeendet"]

    private let store: SoakLogStore

    init(store: SoakLogStore) {
        self.store = store
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Protokoll"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Testseite", style: .plain,
                                                            target: self, action: #selector(openTestPage))
        tableView.tableHeaderView = makeHeader()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: SoakLogStore.didChange, object: store)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0),
                                                  withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        if header.frame.height != size.height {
            header.frame.size.height = size.height
            tableView.tableHeaderView = header
        }
    }

    private func makeHeader() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        for (index, label) in Self.markers.enumerated() {
            let button = UIButton(configuration: .bordered())
            button.setTitle(label, for: .normal)
            button.tag = index
            button.addTarget(self, action: #selector(markerTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    @objc private func markerTapped(_ sender: UIButton) {
        store.append(SoakEntry.make(kind: "marker", marker: Self.markers[sender.tag]))
    }

    @objc private func openTestPage() {
        navigationController?.pushViewController(WebViewController(), animated: true)
    }

    @objc private func reload() {
        tableView.reloadData()
    }

    // Newest first: row 0 is the last entry.
    private func index(for row: Int) -> Int { store.entries.count - 1 - row }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "entry")
        let i = index(for: indexPath.row)
        let entry = store.entries[i]
        let what: String
        switch entry.kind {
        case "launch": what = "Start"
        case "resume": what = "Fortgesetzt"
        default: what = entry.marker ?? entry.kind
        }
        cell.textLabel?.text = "\(entry.t.replacingOccurrences(of: "T", with: " "))  \(what)"
        var details = ["Netz: \(entry.path)", entry.tz]
        if entry.lowPower { details.append("Stromsparen") }
        if i > 0, Self.rebooted(between: store.entries[i - 1], and: entry) { details.append("Neustart erkannt") }
        details.append("\(entry.flavor) \(entry.build)")
        cell.detailTextLabel?.text = details.joined(separator: " · ")
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        return cell
    }

    // A minute of slack, because the kernel nudges the boot time when the clock is corrected.
    static func rebooted(between earlier: SoakEntry, and later: SoakEntry) -> Bool {
        let f = ISO8601DateFormatter()
        guard let a = f.date(from: earlier.bootTime), let b = f.date(from: later.bootTime) else {
            return earlier.bootTime != later.bootTime
        }
        return abs(a.timeIntervalSince(b)) > 60
    }
}
