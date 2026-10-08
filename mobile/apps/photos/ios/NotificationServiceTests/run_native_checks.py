#!/usr/bin/env python3
"""Run signed native checks on an isolated simulator; requires Xcode and Photos pods."""
import json
import pathlib
import plistlib
import platform
import subprocess
import tempfile
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


ios = pathlib.Path(__file__).resolve().parent.parent
bundle_id = "io.ente.frame.debug.NotificationServiceTests"
runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
runtime = max(
    (r for r in runtimes if r["isAvailable"] and ".iOS-" in r["identifier"]),
    key=lambda r: tuple(map(int, r["version"].split("."))),
)
device_type = next(d["identifier"] for d in runtime["supportedDeviceTypes"] if d["productFamily"] == "iPhone")
with tempfile.TemporaryDirectory(prefix="ente-nse-checks-") as directory:
    app = pathlib.Path(directory) / "NativeChecks.app"
    app.mkdir()
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "NativeChecks",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleExecutable": "NativeChecks",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "15.1",
        "LSRequiresIPhoneOS": True,
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "UIDeviceFamily": [1, 2],
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    entitlements = pathlib.Path(directory) / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({
        "application-identifier": "6Z68YJY9Q2." + bundle_id,
        "com.apple.security.application-groups": ["group.io.ente.frame.notifications"],
    }))
    sources = [ios / "NotificationServiceExtension" / name for name in
               ["NotificationKeyStore.swift", "NotificationPayload.swift", "NotificationService.swift"]]
    sources += [ios / "NotificationServiceTests" / name for name in
                ["NotificationPayloadChecks.swift", "NotificationKeyStoreChecks.swift", "NativeChecksApp.swift"]]
    subprocess.run([
        "xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library",
        "-D", "NOTIFICATION_TEST_APP", "-sdk", run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"),
        "-target", platform.machine() + "-apple-ios15.1-simulator",
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", str(entitlements),
        "-import-objc-header", str(ios / "NotificationServiceExtension/Sodium.h"),
        *map(str, sources), str(ios / ".symlinks/plugins/flutter_sodium/ios/prebuilt/libsodium-simulator.a"),
        "-o", str(app / "NativeChecks"),
    ], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    device = run("xcrun", "simctl", "create", "Ente NSE checks", device_type, runtime["identifier"])
    try:
        print("Booting isolated simulator for native checks", flush=True)
        run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b")
        run("xcrun", "simctl", "install", device, str(app))
        try:
            run("xcrun", "simctl", "launch", device, bundle_id)
        except subprocess.CalledProcessError:
            print(run("xcrun", "simctl", "spawn", device, "log", "show", "--last", "1m",
                      "--style", "compact", "--predicate", 'eventMessage CONTAINS "NotificationServiceTests"'))
            raise
        data = pathlib.Path(run("xcrun", "simctl", "get_app_container", device, bundle_id, "data"))
        result = data / "Documents/result.txt"
        deadline = time.monotonic() + 30
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        output = result.read_text()
        print(output)
        if not output.startswith("PASS:"):
            raise SystemExit(1)
    finally:
        run("xcrun", "simctl", "delete", device)
