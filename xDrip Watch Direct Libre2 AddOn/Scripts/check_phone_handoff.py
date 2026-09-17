#!/usr/bin/env python3
"""Exercise phone availability and NFC retirement delivery with WCSession doubles.

Production methods run unchanged; these checks cover dispatch policy, not radio delivery.
"""
from pathlib import Path
from swift_test_runner import run_swift, test_directory

addon = Path(__file__).resolve().parents[1]
source = (addon / 'iPhone/Managers/Libre2PhoneHandoff.swift').read_text()


def declaration(name):
    start = source.index('    ' + name)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


code = r'''
import Foundation
enum Activation { case activated, inactive }
final class WCSession {
    static let `default` = WCSession()
    var activationState = Activation.inactive
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
    var queued: [[String: Any]] = []
    var live: [[String: Any]] = []
    func transferUserInfo(_ message: [String: Any]) { queued.append(message) }
    func sendMessage(_ message: [String: Any], replyHandler: ([String: Any]) -> Void,
                     errorHandler: (Error) -> Void) { live.append(message); replyHandler([:]) }
}
enum Texts_DirectLibre {
    static let watchReachableLog = "reachable"
    static let watchUnreachableLog = "unreachable"
}
final class Libre2ActivityLog {
    static let shared = Libre2ActivityLog()
    var entries: [String] = []
    func record(_ text: String) { entries.append(text) }
}
enum Libre2HandoffMessage { static let retiredIDsKey = "retiredHandoffs" }
struct Record { var retiredIDs: Set<UUID> = [] }
final class Store { var snapshot = Record() }
final class Phone {
    let store = Store()
    private var lastWatchAvailability: WatchAvailability?
    var refreshes = 0
    func refreshChecklist() { refreshes += 1 }
'''
for name in ['var reachable:', 'private struct WatchAvailability:', 'func recordReachability()',
             'private var retiredSessionsDictionary:', 'func notifyWatchOfNFCReset()',
             'private func syncRetiredSessions()']:
    code += declaration(name) + '\n'
code += r'''
}
let phone = Phone()
let session = WCSession.default
let retiredID = UUID()
phone.store.snapshot.retiredIDs.insert(retiredID)
phone.recordReachability()
phone.recordReachability()
precondition(phone.refreshes == 1 && Libre2ActivityLog.shared.entries == ["unreachable"])
session.isPaired = true
phone.recordReachability()
session.isWatchAppInstalled = true
phone.recordReachability()
precondition(phone.refreshes == 3 && Libre2ActivityLog.shared.entries.count == 1)
session.isReachable = true
phone.recordReachability()
precondition(phone.refreshes == 3 && session.live.isEmpty, "Inactive session must remain unavailable")
session.activationState = .activated
phone.recordReachability()
phone.recordReachability()
precondition(phone.refreshes == 4 && session.live.count == 1)
session.isWatchAppInstalled = false
phone.recordReachability()
precondition(phone.refreshes == 5 && session.live.count == 1, "Installation change is not a reachability edge")
session.isReachable = false
phone.recordReachability()
session.isReachable = true
phone.recordReachability()
precondition(session.live.count == 2)
precondition(Libre2ActivityLog.shared.entries == ["unreachable", "reachable", "unreachable", "reachable"])
print("PASS: Named availability refreshes changed fields and reconciles only reachability transitions")

session.live.removeAll()
phone.notifyWatchOfNFCReset()
precondition(session.queued.count == 1 && session.live.count == 1)
for message in session.queued + session.live {
    precondition(message.count == 1 && message[Libre2HandoffMessage.retiredIDsKey] as? [String] == [retiredID.uuidString])
}
session.isReachable = false
phone.notifyWatchOfNFCReset()
precondition(session.queued.count == 2 && session.live.count == 1)
session.activationState = .inactive
phone.notifyWatchOfNFCReset()
precondition(session.queued.count == 2 && session.live.count == 1)
precondition(phone.store.snapshot.retiredIDs == [retiredID])
print("PASS: NFC retirement sends IDs only, queues offline when activated, and retains the journal")
'''
with test_directory('direct-libre-phone-handoff-') as work:
    main = work / 'main.swift'
    main.write_text(code)
    run_swift(work / 'phone-handoff-tests', [main], flags=['-swift-version', '5'])
