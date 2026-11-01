#!/usr/bin/env python3
"""Maintain one private, certificate-pinned local signing identity.

No certificate is added to a trust store. No login/system keychain is modified.
Standard output is public metadata only; secret subprocess arguments and key
material are never logged. An incomplete existing store is never regenerated.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile


class SigningError(Exception):
    pass


def run(label, arguments, secret="", env=None, timeout=30):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True,
                                env=env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SigningError(f"{label} could not finish ({type(error).__name__}).") from None
    if result.returncode != 0:
        detail = result.stderr.strip()
        if secret:
            detail = detail.replace(secret, "[redacted]")
        raise SigningError(f"{label} failed: {detail or result.returncode}")
    return result.stdout


def search_list():
    return shlex.split(run("Read keychain search list",
                          ["/usr/bin/security", "list-keychains", "-d", "user"]))


def remove_own_search_entry(keychain, original):
    # create-keychain may append itself. Remove only our addition, preserving
    # all unrelated changes another application may have made concurrently.
    current = search_list()
    cleaned = [entry for entry in current
               if entry != str(keychain) or entry in original]
    if cleaned != current:
        run("Restore keychain search list",
            ["/usr/bin/security", "list-keychains", "-d", "user", "-s", *cleaned])


def protect_file(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.getuid():
        raise SigningError(f"Signing file is missing, not owned by you, or a symlink: {path}")
    path.chmod(0o600)


def certificate_hash(path):
    output = run("Read signing certificate", ["/usr/bin/openssl", "x509", "-in", str(path),
                 "-noout", "-fingerprint", "-sha1"])
    fingerprint = output.strip().split("=", 1)[-1].replace(":", "").upper()
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise SigningError("Could not read the signing certificate fingerprint.")
    return fingerprint


def create_identity(store):
    keychain = store / "signer.keychain-db"
    certificate = store / "certificate.pem"
    password_file = store / "password"
    password = secrets.token_urlsafe(48)
    password_file.write_text(password, encoding="utf-8")
    password_file.chmod(0o600)
    original_search_list = search_list()
    try:
        with tempfile.TemporaryDirectory(prefix="keyboard-lock-signing-", dir="/private/tmp") as temp:
            temp = Path(temp)
            config = temp / "certificate.cnf"
            config.write_text(
                "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                "[dn]\nCN=Keyboard Lock Local Development\n"
                "[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n"
                "keyUsage=critical,digitalSignature,keyCertSign\n"
                "extendedKeyUsage=critical,codeSigning\n"
                "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
            private_key = temp / "private.pem"
            archive = temp / "identity.p12"
            run("Create local signing certificate", ["/usr/bin/openssl", "req", "-new", "-newkey",
                "rsa:3072", "-nodes", "-x509", "-sha256", "-days", "3650", "-config", str(config),
                "-keyout", str(private_key), "-out", str(certificate)])
            environment = dict(os.environ, KEYBOARD_LOCK_IMPORT_PASSWORD=password)
            run("Prepare signing identity", ["/usr/bin/openssl", "pkcs12", "-export", "-name",
                "Keyboard Lock Local Development", "-inkey", str(private_key), "-in", str(certificate),
                "-out", str(archive), "-passout", "env:KEYBOARD_LOCK_IMPORT_PASSWORD"],
                secret=password, env=environment)
            run("Create dedicated signing keychain", ["/usr/bin/security", "create-keychain",
                "-p", password, str(keychain)], secret=password)
            run("Import local identity", ["/usr/bin/security", "import", str(archive), "-k",
                str(keychain), "-P", password, "-x", "-T", "/usr/bin/codesign"], secret=password)
            # The imported private key is non-extractable. Its trusted-app ACL
            # names only codesign. This partition update is scoped to this new
            # dedicated keychain and does not change certificate trust.
            run("Allow codesign to use its key", ["/usr/bin/security", "set-key-partition-list",
                "-S", "apple-tool:", "-s", "-k", password, str(keychain)], secret=password)
            for path in [keychain, certificate, password_file]:
                protect_file(path)
            record = {"version": 1, "identity_sha1": certificate_hash(certificate)}
            (store / "identity.json").write_text(json.dumps(record) + "\n")
            protect_file(store / "identity.json")
    finally:
        if keychain.exists():
            subprocess.run(["/usr/bin/security", "lock-keychain", str(keychain)], capture_output=True)
        remove_own_search_entry(keychain, original_search_list)


def get_identity(store):
    os.umask(0o077)
    if store.is_symlink():
        raise SigningError("The signing store must not be a symlink.")
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    if store.stat().st_uid != os.getuid():
        raise SigningError("The signing store must be owned by the current user.")
    store.chmod(0o700)
    lock = store / ".lock"
    if lock.is_symlink():
        raise SigningError("The signing lock must not be a symlink.")
    with lock.open("a") as lock_file:
        os.chmod(lock, 0o600)
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        contents = {path.name for path in store.iterdir()} - {".lock"}
        expected = {"identity.json", "signer.keychain-db", "password", "certificate.pem"}
        if not contents:
            create_identity(store)
        elif not expected.issubset(contents):
            raise SigningError("The existing signing store is incomplete. Restore its original files "
                               "from your private backup, or explicitly select an existing "
                               "CODE_SIGN_IDENTITY. A replacement identity was not generated.")
        for name in expected:
            protect_file(store / name)
        try:
            record = json.loads((store / "identity.json").read_text())
            fingerprint = record["identity_sha1"]
            if record["version"] != 1 or not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
                raise ValueError()
        except (KeyError, ValueError, TypeError):
            raise SigningError("The signing metadata is invalid. Restore the original store; "
                               "a replacement identity was not generated.") from None
        if certificate_hash(store / "certificate.pem") != fingerprint:
            raise SigningError("The certificate no longer matches the saved signing identity. "
                               "Restore the original store; no identity was replaced.")
        password = (store / "password").read_text()
        if not password:
            raise SigningError("The signing password file is empty. Restore the original store.")
        keychain = store / "signer.keychain-db"
        try:
            run("Unlock dedicated signing keychain", ["/usr/bin/security", "unlock-keychain",
                "-p", password, str(keychain)], secret=password)
            identities = run("Check dedicated signing identity", ["/usr/bin/security", "find-identity",
                             "-p", "codesigning", str(keychain)])
            if fingerprint not in identities:
                raise SigningError("The dedicated keychain is missing the saved certificate/private key. "
                                   "Restore the original store; no identity was replaced.")
        except SigningError:
            subprocess.run(["/usr/bin/security", "lock-keychain", str(keychain)], capture_output=True)
            raise
        return {"identity_sha1": fingerprint, "keychain": str(keychain),
                "certificate": str(store / "certificate.pem")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path,
                        default=Path.home() / "Library/Application Support/KeyboardLock/Signing")
    args = parser.parse_args()
    try:
        metadata = get_identity(args.store.absolute())
    except (SigningError, OSError) as error:
        print(f"Local signing: {error}", file=sys.stderr)
        return 1
    print(json.dumps(metadata))
    return 0


if __name__ == "__main__":
    sys.exit(main())
