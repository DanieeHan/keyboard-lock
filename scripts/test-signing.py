#!/usr/bin/env python3
"""Test stable local signing using disposable identities and binaries only."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

os.umask(0o077)
setup = Path(__file__).resolve().with_name("local-signing.py")


def run(label, arguments, expected=0):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise RuntimeError(f"{label} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout + result.stderr


def designated_requirement(path):
    text = run("Read requirement", ["/usr/bin/codesign", "--display", "-r-", str(path)])
    return re.search(r"designated => (.+)", text).group(1)


original_search_list = run("Read search list", ["/usr/bin/security", "list-keychains", "-d", "user"])
with tempfile.TemporaryDirectory(prefix="keyboard-lock-signing-test-", dir="/private/tmp") as temp:
    root = Path(temp)
    keychains = []
    try:
        store = root / "signing"
        first = json.loads(run("Create test identity", [sys.executable, str(setup), "--store", str(store)]))
        keychains.append(first["keychain"])
        second = json.loads(run("Reload identity", [sys.executable, str(setup), "--store", str(store)]))
        assert first == second, "Separate setup invocations changed the identity."
        assert (store.stat().st_mode & 0o777) == 0o700
        assert all((p.stat().st_mode & 0o077) == 0 for p in store.iterdir() if p.is_file())
        for name in ["password", "certificate.pem", "identity.json", "signer.keychain-db"]:
            assert ((store / name).stat().st_mode & 0o777) == 0o600
        binaries = []
        for version in [1, 2]:
            source = root / f"v{version}.c"
            binary = root / f"v{version}"
            source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("probe {version}"); return 0; }}\n')
            run("Compile probe", ["/usr/bin/xcrun", "clang", "-Os", str(source), "-o", str(binary)])
            run("Sign probe", ["/usr/bin/codesign", "--force", "--sign", first["identity_sha1"],
                "--keychain", first["keychain"], "--identifier", "local.keyboardlock.signingprobe",
                "--timestamp=none", "--options", "runtime", str(binary)])
            run("Strict verification", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(binary)])
            binaries.append(binary)
        requirement = designated_requirement(binaries[0])
        assert requirement == designated_requirement(binaries[1])
        assert "certificate leaf" in requirement and "cdhash" not in requirement
        run("Cross-version verification", ["/usr/bin/codesign", "--verify", "--strict",
            "-R=" + requirement, str(binaries[1])])
        run("Run test binary", [str(binaries[1])])

        wrong = json.loads(run("Create independent certificate", [sys.executable, str(setup),
                              "--store", str(root / "different-signing")]))
        keychains.append(wrong["keychain"])
        run("Sign with different certificate", ["/usr/bin/codesign", "--force", "--sign",
            wrong["identity_sha1"], "--keychain", wrong["keychain"], "--identifier",
            "local.keyboardlock.signingprobe", "--timestamp=none", str(binaries[1])])
        rejection = subprocess.run(["/usr/bin/codesign", "--verify", "--strict",
                     "-R=" + requirement, str(binaries[1])], capture_output=True, text=True)
        assert rejection.returncode != 0, "A same-name different-certificate file was accepted."

        # Established stores must fail rather than silently minting a new key.
        saved_metadata = (store / "identity.json").read_bytes()
        (store / "certificate.pem").unlink()
        broken = subprocess.run([sys.executable, str(setup), "--store", str(store)],
                                capture_output=True, text=True)
        assert broken.returncode != 0 and "incomplete" in broken.stderr
        assert (store / "identity.json").read_bytes() == saved_metadata
        print("PASS: two setup invocations retain the same protected identity.")
        print("PASS: different builds satisfy the same certificate-pinned requirement.")
        print("PASS: same identifier with another certificate is rejected.")
        print("PASS: incomplete identity store fails without rotation.")
    finally:
        for keychain in set(keychains) | {str(path) for path in root.rglob("*.keychain-db")}:
            subprocess.run(["/usr/bin/security", "delete-keychain", keychain], capture_output=True)
        current = run("Read final search list", ["/usr/bin/security", "list-keychains", "-d", "user"])
        assert current == original_search_list, "The user's keychain search list changed."
        print("PASS: temporary keychains removed; original search list unchanged.")
