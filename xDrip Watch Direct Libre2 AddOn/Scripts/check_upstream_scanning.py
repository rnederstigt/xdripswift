#!/usr/bin/env python3
"""Check the ordinary NFC path against the recorded upstream base.

The explicit Direct Libre hooks are removed for this source comparison. This checks
preservation of the original reader, scan notices and retry path, not hardware behaviour.
"""
from pathlib import Path
import argparse
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', default='53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]

def original(path):
    return subprocess.check_output(['git', '-C', str(repo), 'show', args.baseline + ':' + path], text=True)

def method(source, signature):
    start = source.index('    ' + signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

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

# Nothing in the add-on may introduce a modal sensor alert or a second NFC reader.
addon = repo / 'xDrip Watch Direct Libre2 AddOn'
for file in addon.rglob('*.swift'):
    if 'Tests' in file.parts:
        continue
    source = file.read_text()
    for forbidden in ['UIAlertController', '.alert(', '.confirmationDialog(', 'bluetoothTransmitterDelegate?.error', 'LibreNFC(libreNFCDelegate:', 'force: true']:
        assert forbidden not in source, (file, forbidden)
print('Ordinary NFC reader, sensor callbacks, scan notices and retry UI match the upstream base outside the explicit reset hooks.')
print('No add-on modal alert, second NFC reader or forced ordinary-mode activity logging.')
