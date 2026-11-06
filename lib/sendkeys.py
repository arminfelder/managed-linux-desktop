#!/usr/bin/env python3
"""Type text into a VM console with virsh send-key (US layout), then press Enter.

  sendkeys.py URI VM TEXT

For a console without a guest agent, for example the installer shell on VT2.
"""
import subprocess
import sys
import time

# Without a pause between keys, the guest console drops keys and applies Shift to the wrong key.
DELAY = 0.12

BASE = {
    " ": "KEY_SPACE", "-": "KEY_MINUS", "=": "KEY_EQUAL", "[": "KEY_LEFTBRACE", "]": "KEY_RIGHTBRACE",
    "\\": "KEY_BACKSLASH", ";": "KEY_SEMICOLON", "'": "KEY_APOSTROPHE", "`": "KEY_GRAVE",
    ",": "KEY_COMMA", ".": "KEY_DOT", "/": "KEY_SLASH", "\t": "KEY_TAB",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", '"': "'", "~": "`",
    "<": ",", ">": ".", "?": "/",
}


def keys_for(ch):
    if ch.isascii() and ch.isalpha():
        k = ["KEY_" + ch.upper()]
        return ["KEY_LEFTSHIFT"] + k if ch.isupper() else k
    if ch.isdigit():
        return ["KEY_" + ch]
    if ch in BASE:
        return [BASE[ch]]
    if ch in SHIFTED:
        return ["KEY_LEFTSHIFT"] + keys_for(SHIFTED[ch])
    sys.exit(f"no key for {ch!r}")


def main():
    uri, vm, text = sys.argv[1:4]
    for ch in text:
        subprocess.run(["virsh", "-c", uri, "send-key", vm, "--holdtime", "60"] + keys_for(ch),
                       check=True, stdout=subprocess.DEVNULL)
        time.sleep(DELAY)
    subprocess.run(["virsh", "-c", uri, "send-key", vm, "KEY_ENTER"], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
