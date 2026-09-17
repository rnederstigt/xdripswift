"""Xcode membership and comparisons with ordinary phone/Watch behaviour."""
import json
import plistlib
import re
import subprocess

from test_support import ADDON as addon, REPO as repo, BASELINE, declaration, fixture, run_swift, test_directory


def method(source, signature):
    return declaration(source, "    " + signature)

def integration():
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(repo / "xdrip.xcodeproj/project.pbxproj")
    ]))
    objects = project["objects"]
    paths = {}

    def walk(key, parent):
        item = objects[key]
        base = repo if item.get("sourceTree") == "SOURCE_ROOT" else parent
        path = base / item.get("path", "")
        paths[key] = path
        for child in item.get("children", []):
            walk(child, path)

    walk(objects[project["rootObject"]]["mainGroup"], repo)
    source_sets = {}
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or target.get("name") not in ("xdrip", "xDrip Watch App", "xDrip Watch Complication Extension"):
            continue
        phase = next(objects[key] for key in target["buildPhases"] if objects[key]["isa"] == "PBXSourcesBuildPhase")
        sources = [paths[objects[key]["fileRef"]] for key in phase["files"]]
        assert len(sources) == len(set(sources)), "Duplicate source membership"
        assert all(path.exists() for path in sources), "A source path no longer resolves"
        source_sets[target["name"]] = set(sources)
        print(f'{target["name"]}: {len(sources)} source paths verified')

    for area, target in (("iPhone", "xdrip"), ("Watch", "xDrip Watch App")):
        expected = set((addon / area).rglob("*.swift"))
        other = "xDrip Watch App" if target == "xdrip" else "xdrip"
        assert expected <= source_sets[target], f"Missing {area} source membership"
        assert not expected & source_sets[other], f"{area} code included in the wrong target"

    shared = set((addon / "Shared").rglob("*.swift"))
    complication_sources = source_sets["xDrip Watch Complication Extension"]
    assert set((addon / "Complication").glob("*.swift")) <= complication_sources
    assert not complication_sources & shared, "The original complication needs no add-on sources"
    phone_only = {"Libre2Checklist.swift", "Libre2PhoneSwitchAction.swift", "Libre2PhoneReadingStatus.swift", "Libre2PhoneHistoryUpdate.swift", "Libre2HistoryRegistry.swift"}
    watch_shared = {path for path in shared if path.name not in phone_only}
    assert watch_shared <= source_sets["xDrip Watch App"], "Watch is missing shared helpers"
    assert not {path for path in shared if path.name in phone_only} & source_sets["xDrip Watch App"], "Phone-only helpers must not ship on Watch"
    # The phone retains its original crypto/parser, so the Watch protocol port stays out of iOS.
    assert shared <= source_sets["xdrip"] | source_sets["xDrip Watch App"]
    assert not set((addon / "Tests").rglob("*.swift")) & set.union(*source_sets.values()), "Host tests must not ship in the app"
    print("Add-on membership and platform separation verified.")

    with (repo / "xDrip-Watch-App-Info.plist").open("rb") as file:
        watch_info = plistlib.load(file)
    assert "underwater-depth" in watch_info.get("WKBackgroundModes", [])
    assert "bluetooth-central" in watch_info.get("UIBackgroundModes", [])
    assert "location" in watch_info.get("UIBackgroundModes", [])
    assert watch_info.get("NSLocationWhenInUseUsageDescription")
    assert "audio" not in watch_info.get("UIBackgroundModes", [])
    assert "NSMotionUsageDescription" not in watch_info
    with (repo / "xDrip Watch App/xDrip Watch App.entitlements").open("rb") as file:
        watch_entitlements = plistlib.load(file)
    assert "com.apple.developer.submerged-shallow-depth-and-pressure" not in watch_entitlements
    assert "com.apple.developer.submerged-depth-and-pressure" not in watch_entitlements
    print("Watch Bluetooth, optional location and underwater declarations verified; no audio, Motion usage or depth entitlement.")

    # The host is a single-target watchOS app. The notification constants retain their
    # WKExtension namespace, but constructing its singleton asserts at runtime.
    for source in source_sets["xDrip Watch App"]:
        assert "WKExtension.shared(" not in source.read_text(), f"Extension-only singleton in single-target Watch app: {source}"
    print("Single-target Watch runtime API verified; no WKExtension singleton calls.")


def upstream_scanning():

    def original(path):
        return subprocess.check_output(['git', '-C', str(repo), 'show', BASELINE + ':' + path], text=True)

    def normalized(source):
        return '\n'.join(line.strip() for line in source.splitlines() if line.strip())

    reader_path = 'xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreNFC.swift'
    reader = (repo / reader_path).read_text()
    reader = reader.replace('private let unlockCode: UInt32\n', 'private let unlockCode: UInt32 = 42\n')
    reader = reader.replace(', unlockCode: UInt32 = 42', '')
    reader = reader.replace('        self.unlockCode = unlockCode\n', '')
    assert reader == original(reader_path), 'NFC reader changed beyond the optional reset code'

    path = 'xDrip/BluetoothTransmitter/CGM/Libre/Libre2/CGMLibre2Transmitter.swift'
    current, baseline = (repo / path).read_text(), original(path)
    scan = method(current, 'override func startScanning()')
    scan = scan.replace('                guard directLibre.beginNFC() else { return .nfcScanNeeded }\n', '')
    scan = scan.replace(', unlockCode: self.directLibre.nfcUnlockCode', '')
    assert scan == method(baseline, 'override func startScanning()')
    streaming = method(current, 'func streamingEnabled(')
    streaming = streaming.replace('            guard directLibre.didEnableNFCStreaming() else { return }\n', '')
    assert normalized(streaming) == normalized(method(baseline, 'func streamingEnabled('))
    result = method(current, 'func nfcScanResult(')
    start, end = result.index('        let isDirectLibreReset'), result.index('        // Keep the Core NFC error')
    result = result[:start] + result[end:]
    assert result == method(baseline, 'func nfcScanResult('), 'Original scan success/failure UI changed'
    for signature in ['func received(sensorUID:', 'func received(fram:', 'func nfcScanExpectedDevice(']:
        assert method(current, signature) == method(baseline, signature), signature

    # Sensor/transport code must not introduce scan-time dialogs or another NFC reader.
    # Explicit experimental-page help and user-requested cleanup confirmations are permitted.
    for file in addon.rglob('*.swift'):
        if 'Tests' in file.parts:
            continue
        source = file.read_text()
        for forbidden in ['UIAlertController', 'bluetoothTransmitterDelegate?.error', 'LibreNFC(libreNFCDelegate:', 'force: true']:
            assert forbidden not in source, (file, forbidden)
        if file.parent != addon / 'iPhone/SwiftUIViews':
            assert '.alert(' not in source and '.confirmationDialog(' not in source, file
    print('Ordinary NFC reader, sensor callbacks, scan notices and retry UI match the upstream base outside the explicit reset hooks.')
    print('No add-on scan-time modal, second NFC reader or forced ordinary-mode activity logging.')


def upstream_relay():

    host_path = 'xDrip Watch App/DataModels/WatchStateModel.swift'
    base = subprocess.check_output(['git', '-C', str(repo), 'show', BASELINE + ':' + host_path], text=True)
    current = (repo / host_path).read_text()
    oldbg = method(base, 'private func processBgReadingsFromDictionary')
    outer = method(current, 'private func processWatchPayloadFromDictionary')
    assert outer == method(base, 'private func processWatchPayloadFromDictionary')
    adapter = (addon / 'Watch/DataModels/WatchStateModel+DirectLibre.swift').read_text()
    apply = method(adapter, 'func applyLibreReadings')
    newbg = method(current, 'private func processBgReadingsFromDictionary')
    assert newbg.replace('        guard !directLibre.isDirect else { return false }\n', '') == oldbg
    code = fixture('WatchRelay',
        libre_constants=(addon / 'Shared/Constants/ConstantsLibre2.swift').read_text(),
        reading_pipeline=(addon / 'Shared/Managers/Libre2ReadingPipeline.swift').read_text(),
        display_fields=fixture('RelayFields'),
        receive_payload=outer,
        original_readings=oldbg,
        current_readings=newbg,
        apply_readings=apply)
    with test_directory('direct-libre-relay-') as w:
        (w/'main.swift').write_text(code)
        run_swift(w/'relay-probe', [
            w/'main.swift',
        ])


def phone_alignment():

    def method(path, signature):
        return declaration((repo / path).read_text(), "    " + signature)

    reading = "xDrip/Core Data/classes/BgReading+CoreDataClass.swift"
    max_slope = re.search(r"static let maxSlopeInMinutes = \d+",
        (repo / "xDrip/Constants/ConstantsBGGraphBuilder.swift").read_text())[0]
    code = fixture('PhoneAlignment',
        calculate_slope=method(reading, "func calculateSlope"),
        slope_ordinal=method(reading, "public func slopeOrdinal"),
        max_slope=max_slope,
        glucose_constants=(repo / "xDrip/Constants/ConstantsBloodGlucose.swift").read_text(),
        timestamp_conversion=method("xDrip/Extensions/Date.swift", "func toMillisecondsAsDouble()"),
        unit_conversion=method("xDrip/Extensions/Double.swift", "func mgDlToMmol(mgDl:"),
        find_slope=method("xDrip/Calibration/Protocol/Calibrator.swift", "public func findSlope"),
        phone_payload=method("xDrip/Managers/Watch/WatchManager.swift", "private func currentBgReadings()"),
        receive_preferences=method(str(addon.relative_to(repo) / "Watch/DataModels/WatchStateModel+DirectLibre.swift"),
                 "func receiveDirectLibrePreferences"))

    with test_directory("direct-libre-alignment-") as work:
        source = work / "main.swift"
        source.write_text(code)
        executable = work / "alignment-tests"
        run_swift(executable, [
            addon / "Shared/Constants/ConstantsLibre2.swift",
            addon / "Shared/Protocol/Libre2BLEData.swift",
            addon / "Shared/Managers/Libre2ReadingPipeline.swift",
            source,
        ])
