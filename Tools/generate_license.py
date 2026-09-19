#!/usr/bin/env python3
#
# Copyright (c) 2026 MacShade Authors. All Rights Reserved.
# PROPRIETARY AND CONFIDENTIAL.
# UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
#
"""
MacShade Hardware License Key Generator.

Generates and verifies cryptographic license keys tied to a machine's Hardware ID (HWID).
Usage:
    python3 Tools/generate_license.py --current
    python3 Tools/generate_license.py --hwid MS-XXXX-XXXX-XXXX-XXXX
"""

import argparse
import hashlib
import hmac
import subprocess
import sys

HWID_SALT = "MacShade::HWID::v1::AppleMetal::2026"
LICENSE_SECRET = b"9f8a3c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f"


def get_current_hw_info():
    """Extract IOPlatformUUID and IOPlatformSerialNumber via ioreg on macOS."""
    uuid = "UNKNOWN"
    serial = "UNKNOWN"
    try:
        out = subprocess.check_output(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            stderr=subprocess.DEVNULL,
            encoding="utf-8"
        )
        for line in out.splitlines():
            if "IOPlatformUUID" in line:
                uuid = line.split("=")[-1].strip().strip('"')
            elif "IOPlatformSerialNumber" in line:
                serial = line.split("=")[-1].strip().strip('"')
    except Exception as e:
        sys.stderr.write(f"Warning: could not query ioreg: {e}\n")
    return uuid, serial


def derive_hwid(uuid: str, serial: str) -> str:
    """Derive standard MS-XXXX-XXXX-XXXX-XXXX format from hardware identifiers."""
    payload = f"{uuid}:{serial}:{HWID_SALT}".encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest().upper()
    return f"MS-{digest[0:4]}-{digest[4:8]}-{digest[8:12]}-{digest[12:16]}"


def generate_license_key(hwid: str) -> str:
    """Generate KEY-XXXX-XXXX-XXXX-XXXX from HWID using HMAC-SHA256."""
    norm_hwid = hwid.strip().upper()
    sig = hmac.new(LICENSE_SECRET, norm_hwid.encode("utf-8"), hashlib.sha256).hexdigest().upper()
    return f"KEY-{sig[0:4]}-{sig[4:8]}-{sig[8:12]}-{sig[12:16]}"


def main():
    parser = argparse.ArgumentParser(description="MacShade HWID License Key Generator")
    parser.add_argument("--hwid", type=str, help="Customer Hardware ID (e.g. MS-XXXX-XXXX-XXXX-XXXX)")
    parser.add_argument("--current", action="store_true", help="Generate key for current Mac hardware")
    args = parser.parse_args()

    if args.current:
        uuid, serial = get_current_hw_info()
        hwid = derive_hwid(uuid, serial)
        key = generate_license_key(hwid)
        print("==================================================")
        print("           MacShade Hardware License               ")
        print("==================================================")
        print(f"Machine UUID:    {uuid}")
        print(f"Machine Serial:  {serial}")
        print(f"Hardware ID:     {hwid}")
        print(f"License Key:     {key}")
        print("==================================================")
        return

    if args.hwid:
        hwid = args.hwid.strip().upper()
        if not hwid.startswith("MS-") or len(hwid.split("-")) != 5:
            print(f"Error: Invalid HWID format '{args.hwid}'. Expected format: MS-XXXX-XXXX-XXXX-XXXX", file=sys.stderr)
            sys.exit(1)
        key = generate_license_key(hwid)
        print("==================================================")
        print("           MacShade License Key Issued            ")
        print("==================================================")
        print(f"Hardware ID:     {hwid}")
        print(f"License Key:     {key}")
        print("==================================================")
        return

    parser.print_help()


if __name__ == "__main__":
    main()
