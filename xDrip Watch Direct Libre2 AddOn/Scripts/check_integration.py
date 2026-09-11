#!/usr/bin/env python3
"""Check the add-on's Xcode source membership without compiling or changing files."""
from pathlib import Path
import json
import plistlib
import subprocess

repo = Path(__file__).resolve().parents[2]
addon = Path(__file__).resolve().parents[1]
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
    if target.get("isa") != "PBXNativeTarget" or target.get("name") not in ("xdrip", "xDrip Watch App"):
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
assert shared <= source_sets["xDrip Watch App"], "Watch is missing shared helpers"
# The phone retains its original PreLibre2/crypto/parser, so not every protocol helper belongs in iOS.
assert shared <= source_sets["xdrip"] | source_sets["xDrip Watch App"]
assert not set((addon / "Tests").rglob("*.swift")) & set.union(*source_sets.values()), "Host tests must not ship in the app"
print("Add-on membership and platform separation verified.")

with (repo / "xDrip-Watch-App-Info.plist").open("rb") as file:
    watch_info = plistlib.load(file)
assert "underwater-depth" in watch_info.get("WKBackgroundModes", [])
assert "bluetooth-central" in watch_info.get("UIBackgroundModes", [])
assert "NSMotionUsageDescription" not in watch_info
with (repo / "xDrip Watch App/xDrip Watch App.entitlements").open("rb") as file:
    watch_entitlements = plistlib.load(file)
assert "com.apple.developer.submerged-shallow-depth-and-pressure" not in watch_entitlements
assert "com.apple.developer.submerged-depth-and-pressure" not in watch_entitlements
print("Minimal Watch foreground configuration verified; no Motion usage or depth entitlement.")
