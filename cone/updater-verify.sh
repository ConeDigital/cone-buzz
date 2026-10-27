#!/usr/bin/env bash
# Verifies a Tauri updater signature the way an installed Cone app does before
# it installs an update (Slice 29 merge 3): the archive's minisign signature,
# made by the updater key, checked against a public key.
#
#   cone/updater-verify.sh [--key-id-only] <archive> <archive.sig> <pubkey-file>
#
# Both files are Tauri's: base64 of minisign's text formats. The signature's
# key id must be the public key's; its Ed25519 signature must hold over the
# archive (BLAKE2b-512 of it for the prehashed "ED" algorithm, which `tauri
# signer sign` writes); and the global signature must hold over the signature
# and its trusted comment. --key-id-only stops after the key id (the release
# build, on a runner whose OpenSSL may predate Ed25519); the promote job runs
# everything. Needs python3, and for the signatures OpenSSL 3 (CONE_OPENSSL,
# else `openssl`, else Homebrew's openssl@3). Exits 0 when it holds, 1 when
# it does not, 2 on a usage or tool error.
set -euo pipefail

key_id_only=0
if [[ "${1:-}" == --key-id-only ]]; then key_id_only=1; shift; fi
(( $# == 3 )) || { echo "usage: cone/updater-verify.sh [--key-id-only] <archive> <archive.sig> <pubkey-file>" >&2; exit 2; }

openssl=""
if (( ! key_id_only )); then
  for o in "${CONE_OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if [[ -z "$o" ]] || ! command -v "$o" >/dev/null 2>&1; then continue; fi
    if "$o" version 2>/dev/null | grep -q '^OpenSSL [3-9]'; then openssl="$(command -v "$o")"; break; fi
  done
  [[ -n "$openssl" ]] || { echo "updater-verify: no OpenSSL 3 for Ed25519 (set CONE_OPENSSL)" >&2; exit 2; }
fi

CONE_OPENSSL="$openssl" CONE_KEY_ID_ONLY="$key_id_only" python3 - "$@" <<'PY'
import base64, hashlib, os, subprocess, sys, tempfile

archive, sig_path, pub_path = sys.argv[1:4]

def fail(msg):
    print(f"updater-verify: REFUSED {os.path.basename(archive)}: {msg}", file=sys.stderr)
    sys.exit(1)

def lines_of(path, what):
    try:
        text = base64.b64decode(open(path, "rb").read().strip(), validate=True).decode()
    except Exception:
        fail(f"{what} is not base64 of minisign text")
    return text.rstrip("\n").split("\n")

pub = lines_of(pub_path, "the public key")
if len(pub) < 2:
    fail("the public key has no key line")
pk = base64.b64decode(pub[1])
if len(pk) != 42 or pk[:2] != b"Ed":
    fail("the public key is not an Ed25519 minisign key")
pk_id, pk_raw = pk[2:10], pk[10:]

sig = lines_of(sig_path, "the signature")
if len(sig) != 4 or not sig[2].startswith("trusted comment: "):
    fail("the signature is not a minisign signature")
s = base64.b64decode(sig[1])
if len(s) != 74 or s[:2] not in (b"ED", b"Ed"):
    fail("the signature's algorithm is unknown")
alg, sig_id, sig_raw = s[:2], s[2:10], s[10:]
trusted = sig[2][len("trusted comment: "):].encode()
global_sig = base64.b64decode(sig[3])

def hexid(b):
    return b[::-1].hex().upper()   # minisign prints the id little-endian

if sig_id != pk_id:
    fail(f"signed by key {hexid(sig_id)}, not {hexid(pk_id)}")
if os.environ["CONE_KEY_ID_ONLY"] == "1":
    print(f"updater-verify: key id {hexid(pk_id)} (signature not checked: --key-id-only)")
    sys.exit(0)

data = open(archive, "rb").read()
message = hashlib.blake2b(data, digest_size=64).digest() if alg == b"ED" else data
der = bytes.fromhex("302a300506032b6570032100") + pk_raw   # SubjectPublicKeyInfo, Ed25519

def ed25519_holds(msg, signature):
    with tempfile.TemporaryDirectory() as d:
        for name, content in (("pub.der", der), ("msg", msg), ("sig", signature)):
            with open(os.path.join(d, name), "wb") as f:
                f.write(content)
        r = subprocess.run([os.environ["CONE_OPENSSL"], "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
                            "-inkey", os.path.join(d, "pub.der"), "-rawin", "-in", os.path.join(d, "msg"),
                            "-sigfile", os.path.join(d, "sig")], capture_output=True, text=True)
        if r.returncode not in (0, 1) or ("Signature Verified Successfully" not in r.stdout
                                          and "Signature Verification Failure" not in r.stdout):
            print(f"updater-verify: openssl failed: {r.stderr.strip()}", file=sys.stderr)
            sys.exit(2)
        return r.returncode == 0 and "Signature Verified Successfully" in r.stdout

if not ed25519_holds(message, sig_raw):
    fail(f"the signature does not hold over this file (key {hexid(pk_id)})")
if not ed25519_holds(sig_raw + trusted, global_sig):
    fail("the trusted comment's signature does not hold")
print(f"updater-verify: ok {os.path.basename(archive)} — key {hexid(pk_id)}, {alg.decode()}, trusted comment: {trusted.decode()}")
PY
