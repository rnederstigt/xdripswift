import Foundation

/// Opt-in lifecycle evidence for the existing activity report. No delivery or wake-up requests.
enum Libre2LifecycleDiagnostics {
    static let processID = String(UUID().uuidString.prefix(8))

    struct Event {
        let name: String
        let date: Date
        let uptime: TimeInterval

        init(_ name: String, date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            self.name = name
            self.date = date
            self.uptime = uptime
        }
    }

    /// Call on main. Preserve callback-entry time when its record waited for the main queue.
    static func record(_ event: Event, details: String, log: Libre2ActivityLog = .shared) {
        guard log.isTracingEnabled else { return }
        let delay = max(0, ProcessInfo.processInfo.systemUptime - event.uptime) * 1000
        log.record("Lifecycle: \(event.name) | process=\(processID)"
            + " uptime=\(String(format: "%.3f", event.uptime))"
            + " logWaitMs=\(String(format: "%.1f", delay)) | \(details)", now: event.date)
    }
}

#if os(iOS) || os(watchOS)
import WatchConnectivity
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

extension Libre2LifecycleDiagnostics {
    private static var observers: [NSObjectProtocol] = []

    static func recordNotification(_ event: String, identifier: String) {
        // The phone's ConstantsNotifications identifier is forwarded unchanged to Watch.
        // Classify it instead of logging arbitrary notification IDs or content.
        recordSession(event, details: "missedReading=\(identifier == "missedReadingAlert")"
            + " notificationTest=\(identifier == Libre2NotificationTest.identifier)")
    }

    /// Install once per process; the callbacks remain silent while detailed tracing is off.
    static func start() {
        guard observers.isEmpty else { return }
        let notifications: [(Notification.Name, String)]
        #if os(watchOS)
        notifications = [
            (WKExtension.applicationDidFinishLaunchingNotification, "App did finish launching"),
            (WKExtension.applicationDidBecomeActiveNotification, "App became active"),
            (WKExtension.applicationWillResignActiveNotification, "App will resign active"),
            (WKExtension.applicationWillEnterForegroundNotification, "App will enter foreground"),
            (WKExtension.applicationDidEnterBackgroundNotification, "App entered background")
        ]
        #else
        notifications = [
            (UIApplication.didBecomeActiveNotification, "App became active"),
            (UIApplication.willResignActiveNotification, "App will resign active"),
            (UIApplication.willEnterForegroundNotification, "App will enter foreground"),
            (UIApplication.didEnterBackgroundNotification, "App entered background")
        ]
        #endif
        observers = notifications.map { name, event in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                recordSession(event)
            }
        }
    }

    /// WC state and entry time are captured at the callback, before dispatching to main.
    /// App state is sampled on main and labelled separately; no notification payload is logged.
    static func recordSession(_ name: String, session: WCSession? = nil, details: String = "") {
        guard UserDefaults.standard.bool(forKey: Libre2ActivityLog.tracingKey) else { return }
        let event = Event(name)
        // App/notification hooks must not instantiate WCSession earlier than normal startup.
        let connection = session.map {
            "activation=\($0.activationState.rawValue) reachable=\($0.isReachable) pendingContent=\($0.hasContentPending)"
        } ?? "WC=notSampled"
        let write = {
            #if os(watchOS)
            let state = WKApplication.shared().applicationState
            #else
            let state = UIApplication.shared.applicationState
            #endif
            let appState = state == .active ? "active" : state == .inactive ? "inactive" : "background"
            record(event, details: "\(connection) appStateAtLog=\(appState) \(details)")
        }
        if Thread.isMainThread { write() } else { DispatchQueue.main.async(execute: write) }
    }
}
#endif
