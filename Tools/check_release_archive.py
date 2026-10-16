#!/usr/bin/env python3
"""Check one local archive without uploading or reading workspace content."""
import argparse
import json
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path


def info_for(bundle):
    for relative in ("Info.plist", "Contents/Info.plist", "Resources/Info.plist", "Versions/A/Resources/Info.plist"):
        candidate = bundle / relative
        if candidate.is_file():
            return plistlib.loads(candidate.read_bytes())
    raise ValueError(f"No bundle Info.plist: {bundle}")


def check_runtime(app, required=False):
    runtime = app / "Contents/Resources/BackgroundService/PythonRuntime"
    if not runtime.is_dir():
        assert not required, "Public advanced Mac package is missing its offline runtime"
        return None
    manifest = json.loads((runtime / "manifest.json").read_text())
    assert set(manifest["architectures"]) == {"arm64", "x86_64"}, "Runtime must support both Mac architectures"
    assert (runtime / "Notices/README.txt").is_file(), "Missing runtime notices"
    magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    signed = 0
    for architecture in manifest["architectures"]:
        prefix = runtime / architecture / "python"
        assert (prefix / "bin/python3").is_file(), "Missing runtime executable"
        assert list((runtime / "Notices" / architecture).glob("*.txt")), "Missing dependency licenses"
        count = 0
        for path in prefix.rglob("*"):
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as source:
                if source.read(4) not in magic:
                    continue
            subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)
            signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(path)], check=True, capture_output=True).stderr.decode()
            assert "Authority=Developer ID Application:" in signature, "Runtime binary is not Developer ID signed"
            assert "TeamIdentifier=MF8J7AY2X3" in signature and "runtime" in signature, "Runtime team/hardening mismatch"
            assert "Timestamp=" in signature, "Runtime signature lacks a secure timestamp"
            raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)], check=True, capture_output=True).stdout
            entitlements = plistlib.loads(raw) if raw.startswith(b"<?xml") else {}
            for key in ("com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory"):
                assert not entitlements.get(key), "Unsafe runtime entitlement: " + key
            count += 1
        assert count > 0, "No signed native runtime binaries found for " + architecture
        signed += count
    return {"architectures": manifest["architectures"], "signed_hardened_timestamped_macho_files": signed, "checks": "passed"}


def check_app(app, distribution=False, developer_id=False, require_runtime=False):
    host = info_for(app)
    if (app / "Contents/MacOS").is_dir() and (app / "Contents/Frameworks/BetterWorkspaceCore.framework").is_dir():
        executable = app / "Contents/MacOS" / host["CFBundleExecutable"]
        load_commands = subprocess.run(["otool", "-l", str(executable)], check=True, capture_output=True, text=True).stdout
        assert "path @executable_path/../Frameworks (offset " in load_commands, "Native Mac executable cannot resolve its embedded Core framework without Xcode's loader"
    version = (host["CFBundleShortVersionString"], host["CFBundleVersion"])
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
    bundles = [app]
    for pattern in ("PlugIns/*.appex", "Frameworks/*.framework", "Contents/PlugIns/*.appex", "Contents/Frameworks/*.framework"):
        bundles += list(app.glob(pattern))
    result = []
    for bundle in bundles:
        info = info_for(bundle)
        assert (info["CFBundleShortVersionString"], info["CFBundleVersion"]) == version, "Bundle version mismatch"
        assert list(bundle.rglob("PrivacyInfo.xcprivacy")), f"Missing privacy resource: {bundle.name}"
        signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(bundle)], capture_output=True, check=True).stderr.decode()
        assert "TeamIdentifier=MF8J7AY2X3" in signature, f"Unexpected team: {bundle.name}"
        if distribution:
            assert "Authority=Apple Distribution:" in signature, f"Not distribution signed: {bundle.name}"
        if developer_id:
            assert "Authority=Developer ID Application:" in signature, f"Not Developer ID signed: {bundle.name}"
            assert "runtime" in signature, f"Hardened runtime missing: {bundle.name}"
        row = {"bundle": bundle.name, "id": info["CFBundleIdentifier"], "version": version[0], "build": version[1]}
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)], capture_output=True, check=True).stdout
        entitlements = plistlib.loads(raw) if raw.startswith(b"<?xml") else {}
        row["cloud_environment"] = entitlements.get("com.apple.developer.icloud-container-environment")
        push_key = "aps-environment" if "MinimumOSVersion" in host else "com.apple.developer.aps-environment"
        row["push_environment"] = entitlements.get(push_key)
        row["debugger_allowed"] = any(entitlements.get(key, False) for key in ("get-task-allow", "com.apple.security.get-task-allow"))
        if distribution or developer_id:
            assert not row["debugger_allowed"], f"Debugger enabled: {bundle.name}"
            if entitlements.get("com.apple.developer.icloud-container-identifiers"):
                assert row["cloud_environment"] == "Production", f"Non-production CloudKit: {bundle.name}"
            if bundle == app and host.get("BWNotebookCloudSyncEnabled"):
                assert row["push_environment"] == "production", "Personal sync requires production push entitlement"
        row["hardened_runtime"] = "runtime" in signature
        for relative in ("embedded.mobileprovision", "Contents/embedded.provisionprofile"):
            profile = bundle / relative
            if not profile.is_file():
                continue
            raw = subprocess.run(["security", "cms", "-D", "-i", str(profile)], capture_output=True, check=True).stdout
            data = plistlib.loads(raw)
            assert "MF8J7AY2X3" in data["TeamIdentifier"]
            app_id = data["Entitlements"].get("application-identifier", data["Entitlements"].get("com.apple.application-identifier", ""))
            assert app_id.endswith("." + info["CFBundleIdentifier"]), "Profile identifier mismatch"
            if distribution:
                assert not data.get("ProvisionedDevices") and not data.get("ProvisionsAllDevices"), "Not a Store profile"
                assert not any(data["Entitlements"].get(key, False) for key in ("get-task-allow", "com.apple.security.get-task-allow")), "Store profile permits debugging"
            if row["push_environment"]:
                assert data["Entitlements"].get(push_key) == row["push_environment"], "Push/profile mismatch"
            row["profile"] = {"name": data["Name"], "expiration": data["ExpirationDate"].isoformat(),
                              "contains_devices": bool(data.get("ProvisionedDevices"))}
        result.append(row)
    if "MinimumOSVersion" in host:
        assert len(host.get("UISupportedInterfaceOrientations~ipad", [])) == 4
        assert host.get("ITSAppUsesNonExemptEncryption") is False
    runtime = check_runtime(app, required=require_runtime) if require_runtime or developer_id else None
    return {"packaging_checks": "passed", "distribution": distribution, "developer_id": developer_id, "bundles": result, "offline_runtime": runtime,
            "note": "Packaging verification does not establish App Store review, production CloudKit or notarization readiness."}


def check(archive, require_runtime=False):
    if archive.suffix == ".app":
        result = check_app(archive, developer_id=True, require_runtime=require_runtime)
    elif archive.suffix == ".ipa":
        assert not require_runtime, "The embedded Python runtime is exclusive to the advanced Mac download"
        with tempfile.TemporaryDirectory(prefix="bw-ipa-check-") as temporary:
            root = Path(temporary).resolve()
            with zipfile.ZipFile(archive) as package:
                assert all((root / name).resolve().is_relative_to(root) for name in package.namelist()), "Unsafe package path"
                package.extractall(root)
            apps = list((root / "Payload").glob("*.app"))
            assert len(apps) == 1, "Expected one host app"
            result = check_app(apps[0], distribution=True)
    elif archive.suffix == ".pkg":
        assert not require_runtime, "The embedded Python runtime is exclusive to the advanced Mac download"
        signature = subprocess.run(["pkgutil", "--check-signature", str(archive)],
                                   check=True, capture_output=True, text=True).stdout
        assert "3rd Party Mac Developer Installer:" in signature and "(MF8J7AY2X3)" in signature, "Unexpected Store installer identity"
        with tempfile.TemporaryDirectory(prefix="bw-store-pkg-check-") as temporary:
            expanded = Path(temporary) / "expanded"
            subprocess.run(["pkgutil", "--expand-full", str(archive.resolve()), str(expanded)],
                           check=True, capture_output=True)
            apps = list(expanded.rglob("*.app"))
            assert len(apps) == 1, "Expected one Store host app"
            result = check_app(apps[0], distribution=True)
            entitlements = plistlib.loads(subprocess.run(
                ["codesign", "-d", "--entitlements", ":-", str(apps[0])],
                check=True, capture_output=True).stdout)
            assert entitlements.get("com.apple.security.app-sandbox") is True, "Store Mac app is not sandboxed"
            assert not (apps[0] / "Contents/Resources/BackgroundService").exists(), "Advanced service must not ship in the Store app"
            result["store_installer_signature"] = "passed"
            result["sandboxed"] = True
    else:
        products = archive / "Products"
        assert sorted(p.name for p in products.iterdir()) == ["Applications"], "Archive has loose installable products"
        apps = list((products / "Applications").glob("*.app"))
        assert len(apps) == 1, "Expected one host app"
        result = check_app(apps[0], require_runtime=require_runtime)
    result["artifact"] = archive.name
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--require-embedded-runtime", action="store_true", help="Required for new advanced Mac downloads; historical candidate 3 has no offline runtime")
    args = parser.parse_args()
    result = check(args.archive, require_runtime=args.require_embedded_runtime)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.report:
        args.report.write_text(encoded)
    print(encoded)
