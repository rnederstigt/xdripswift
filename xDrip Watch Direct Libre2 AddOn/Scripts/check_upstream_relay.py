#!/usr/bin/env python3
"""Compare ordinary Watch relay with the upstream base using extracted Swift methods.

Runs on macOS with Xcode. Requires the baseline commit locally; performs no fetch.
Complication calls are counted, not sent to WidgetKit. Display formatting is stubbed.
Temporary build products are removed automatically, outside the repository.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', default='53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8')
args = parser.parse_args()
r = Path(__file__).resolve().parents[2]

def method(s,name):
 start=s.index('    '+name); brace=s.index('{',start);depth=1;i=brace+1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start:i]
base=subprocess.check_output(['git','-C',str(r),'show',args.baseline + ':xDrip Watch App/DataModels/WatchStateModel.swift'],text=True)
current=(r/'xDrip Watch App/DataModels/WatchStateModel.swift').read_text()
oldbg=method(base,'private func processBgReadingsFromDictionary')
outer=method(current,'private func processWatchPayloadFromDictionary')
assert outer==method(base,'private func processWatchPayloadFromDictionary')
apply=method((r/'xDrip Watch Direct Libre2 AddOn/Watch/DataModels/WatchStateModel+DirectLibre.swift').read_text(),'func applyLibreReadings')
common='''
    var directLibre = DirectMode()
    var bgReadingValues: [Double] = [] { didSet { applied += 1 } }
    var bgReadingDates: [Date] = []
    var bgReadingDatesAsDouble: [Double] = []
    var slopeOrdinal = 0
    var deltaValueInUserUnit: Double = 0
    var updatedDate = Date(timeIntervalSince1970: 0)
    var lastUpdatedTextString = ""
    var lastUpdatedTimeString = ""
    var lastUpdatedTimeAgoString = ""
    var applied = 0
    var complicationUpdates = 0
    func bgReadingDate() -> Date? { bgReadingDates.first }
    func updateComplicationData() { complicationUpdates += 1 }
    private func processStatusFromDictionary(dictionary: [String: Any]) -> Bool { false }
    private func processAGPFromDictionary(dictionary: [String: Any]) {}
    func deliver(_ payload: [String: Any]) { processWatchPayloadFromDictionary(dictionary: ["bgReadings": payload]) }
'''
newbg=method(current,'private func processBgReadingsFromDictionary')
assert newbg.replace('        guard !directLibre.isDirect else { return false }\n','') == oldbg
code='''import Foundation
struct Libre2Sample { let timeStamp: Date; let glucoseLevelRaw: Double }
final class DirectMode { var isDirect = false }
enum Texts_WatchApp { static let lastReading = "Last reading"; static let noSensorData = "No data" }
extension Date { func daysAndHoursAgo(appendAgo: Bool) -> String { "display formatting stub" } }
'''+(r/'xDrip Watch Direct Libre2 AddOn/Shared/Managers/Libre2ReadingPipeline.swift').read_text()+ '\nfinal class UpstreamWatch {\n'+common+outer+'\n'+oldbg+'\n}\nfinal class AddOnWatch {\n'+common+outer+'\n'+newbg+"\n"+apply+'''
    func deliverDirect(_ batch: Libre2ReadingBatch) {
        guard batch.isAcceptable(after: bgReadingDates.first) else { return }
        applyLibreReadings(batch)
    }
}\n'''+'''
let now = Date()
let cases: [(String, [Double]?, [Double])] = [
    ("normal fresh", [110, 108], [-30, -90]),
    ("older recent replacement", [110, 108], [-120, -180]),
    ("future timestamp", [110, 108], [120, 60]),
    ("zero historical value", [110, 0], [-30, -90]),
    ("missing values", nil, [-30]),
    ("mismatched arrays", [110], [-30, -90]),
    ("over an hour old", [110], [-7200])
]
for (name, values, offsets) in cases {
    let upstream = UpstreamWatch(), addOn = AddOnWatch()
    upstream.bgReadingDates = [now.addingTimeInterval(-60)]
    addOn.bgReadingDates = upstream.bgReadingDates
    var payload: [String: Any] = ["bgReadingDatesAsDouble": offsets.map { now.addingTimeInterval($0).timeIntervalSince1970 }, "generatedAt": now.timeIntervalSince1970]
    if let values { payload["bgReadingValues"] = values }
    upstream.deliver(payload); addOn.deliver(payload)
    print("\\(name): upstream accepted=\\(upstream.applied > 0), complication calls=\\(upstream.complicationUpdates); add-on accepted=\\(addOn.applied > 0), complication calls=\\(addOn.complicationUpdates)")
    precondition(upstream.complicationUpdates == addOn.complicationUpdates, name)
    precondition(upstream.applied == addOn.applied, name)
    precondition(upstream.bgReadingValues == addOn.bgReadingValues, name)
    precondition(upstream.bgReadingDates == addOn.bgReadingDates, name)
    precondition(upstream.updatedDate == addOn.updatedDate, name)
    addOn.directLibre.isDirect = true
    let previousUpdates = addOn.complicationUpdates
    addOn.deliver(payload)
    precondition(addOn.complicationUpdates == previousUpdates, "Relay overwrote direct mode")
}
'''
code += """
let direct = AddOnWatch()
direct.deliverDirect(Libre2ReadingBatch(values: [110], dates: [now.timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now))
precondition(direct.complicationUpdates == 1)
direct.deliverDirect(Libre2ReadingBatch(values: [0], dates: [now.timeIntervalSince1970], slope: 4, delta: 0, generatedAt: now))
precondition(direct.complicationUpdates == 1)
print("Direct samples: valid refreshes once; malformed sample rejected. Relay blocked while direct.")
"""
with tempfile.TemporaryDirectory(prefix='direct-libre-relay-') as directory:
    w = Path(directory)
    (w/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(w/'module-cache'),
                    str(w/'main.swift'), '-o', str(w/'relay-probe')], check=True)
    subprocess.run([str(w/'relay-probe')], check=True)
