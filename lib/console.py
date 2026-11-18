#!/usr/bin/env python3
"""Watch the serial console of the client VM during boot.

  console.py URI VM unlock [start]           type $LUKS_PASSPHRASE at each prompt (max 3 tries)
  console.py URI VM expect-no-prompt [start] fail if a passphrase prompt appears (TPM2/FIDO2 test)
  console.py URI VM expect-prompt [start]    as unlock, but fail if no passphrase prompt appears (TPM2 must refuse)
  console.py URI VM mok [start]              enroll the pending MOK in MokManager ($MOK_PASSWORD), then unlock

With "start", virsh starts the shut-off VM and attaches the console before the first output.

Exit 0 when a login prompt appears. The serial output goes to $CONSOLE_LOG.
virsh console needs a terminal, so it runs on a pty.
"""
import os
import pty
import re
import select
import sys
import time

# systemd-ask-password draws the prompt again after each key, with one '*' per key.
# Only a prompt with no '*' after the colon is a new prompt (first prompt or a retry after a wrong passphrase).
# With a recovery key enrolled, the text is "passphrase or recovery key for disk ...".
PROMPT = re.compile(rb"(?i)passphrase[^\r\n:]* for [^\r\n:]*:(?!\*)")
PROMPT_AT_END = re.compile(rb"(?i)passphrase[^\r\n:]* for [^\r\n:]*: ?$")
LOGIN = re.compile(rb"login: ?$", re.M)
BANNER = re.compile(rb"(Connected to domain|Escape character)[^\n]*\n?")
TIMEOUT = int(os.environ.get("CONSOLE_TIMEOUT", "600"))
# OVMF sends the firmware text console to the serial port as ANSI. Matches ignore the escape sequences.
ANSI = re.compile(rb"\x1b(\[[0-9;?]*[A-Za-z]|[()][A-Z0-9])")
DOWN = b"\x1b[B"
# MokManager menus, strings from shim 15.8 mmx64.efi. Each step: wait for the text, then send the keys.
# The menu order is fixed: "Continue boot" comes before "Enroll MOK", "View key 0" before "Continue", "No" before "Yes".
MOK_STEPS = [
    (rb"Press any key to perform MOK management", b"\r"),
    (rb"Perform MOK management.*Enroll MOK", DOWN + b"\r"),
    (rb"\[Enroll MOK\].*View key 0.*Continue", DOWN + b"\r"),
    (rb"Enroll the key\(s\)\?", DOWN + b"\r"),
    (rb"Password:", None),
    (rb"Reboot", b"\r"),
]
MOK_ERROR = re.compile(rb"Password doesn't match|Password limit reached|Failed to enroll keys")


def parse_args():
    uri, vm, mode = sys.argv[1:4]
    start = sys.argv[4:5] == ["start"]
    if mode not in ("unlock", "expect-no-prompt", "expect-prompt", "mok"):
        sys.exit(f"unknown mode {mode}")
    unlock = mode != "expect-no-prompt"
    secret = os.environ.get("LUKS_PASSPHRASE", "").encode()
    if unlock and not secret:
        sys.exit("LUKS_PASSPHRASE is empty")
    mok_pw = os.environ.get("MOK_PASSWORD", "").encode()
    if mode == "mok" and not mok_pw:
        sys.exit("MOK_PASSWORD is empty")
    return uri, vm, mode, start, secret, mok_pw


def mok_stop(text):
    """The reason to stop the MokManager steps, or None."""
    if PROMPT.search(text) or LOGIN.search(text):
        return "boot went on without MokManager: no MOK request, or the key press came too late"
    # Without MokNew, MokManager offers "Reset MOK" (delete all MOKs). That item must never get a key.
    if re.search(rb"Continue boot.*Reset MOK", text, re.S) and b"Enroll MOK" not in text:
        return "MokManager has no pending MOK (menu shows Reset MOK): select Continue boot by hand"
    m = MOK_ERROR.search(text)
    if m:
        return f"MokManager: {m.group().decode()}"
    return None


class Watch:
    def __init__(self, fd, log, mode, start, secret, mok_pw):
        self.fd, self.log, self.mode, self.start = fd, log, mode, start
        self.secret, self.mok_pw = secret, mok_pw
        self.unlock = mode != "expect-no-prompt"
        self.steps = list(MOK_STEPS) if mode == "mok" else []
        self.buf, self.tries, self.rc = b"", 0, 1

    def run(self):
        end = time.time() + TIMEOUT
        self.attached = self.quiet_since = time.time()
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 1)
            if r and not self.read():
                break
            if self.steps:
                if self.mok_step():
                    break
                continue
            if self.luks_step(r):
                break
        else:
            print(f"no login prompt after {TIMEOUT}s", file=sys.stderr)

    def read(self):
        try:
            chunk = os.read(self.fd, 4096)
        except OSError:
            print("console closed", file=sys.stderr)
            return False
        self.log.write(chunk)
        self.log.flush()
        # MokManager draws full screens with box characters: one menu is more than 8 KiB on the serial port.
        self.buf = (self.buf + chunk)[-(65536 if self.steps else 4096):]
        self.quiet_since = time.time()
        return True

    def mok_step(self):
        """Send the keys of the next MokManager step. True: stop."""
        # A menu is complete only after 1 s without output.
        text = ANSI.sub(b"", self.buf)
        reason = mok_stop(text)
        if reason:
            print(reason, file=sys.stderr)
            return True
        pattern, keys = self.steps[0]
        first = len(self.steps) == len(MOK_STEPS)
        if re.search(pattern, text, re.S) and (first or time.time() - self.quiet_since > 1):
            self.buf = b""
            self.steps.pop(0)
            if keys is None:
                # MokManager reads the password one key at a time.
                for ch in self.mok_pw:
                    os.write(self.fd, bytes([ch]))
                    time.sleep(0.1)
                keys = b"\r"
            os.write(self.fd, keys)
            print(f"MokManager: {pattern.decode()}", file=sys.stderr)
        return False

    def fresh_prompt(self, r):
        # A prompt at the end of the buffer counts only after 1 s without output: the first '*' can still come.
        m = PROMPT.search(self.buf)
        fresh = (m and m.end() < len(self.buf)) or (not r and PROMPT_AT_END.search(self.buf))
        # "unlock" without "start": the prompt is open already and prints nothing new.
        guest = BANNER.sub(b"", self.buf).strip()
        if not self.start and self.mode == "unlock" and self.tries == 0 and not guest \
                and time.time() - self.attached > 3:
            fresh = True
        return fresh

    def luks_step(self, r):
        """Answer a passphrase prompt or detect the login prompt. True: stop."""
        if self.fresh_prompt(r):
            return self.send_passphrase()
        if LOGIN.search(self.buf):
            print("login prompt on the serial console", file=sys.stderr)
            if self.mode == "expect-prompt" and self.tries == 0:
                print("no passphrase prompt: the token unlocked the disk", file=sys.stderr)
            else:
                self.rc = 0
            return True
        return False

    def send_passphrase(self):
        self.buf = b""
        if not self.unlock:
            print("passphrase prompt appeared: the token did not unlock the disk", file=sys.stderr)
            return True
        self.tries += 1
        if self.tries > 3:
            print("passphrase rejected 3 times", file=sys.stderr)
            return True
        time.sleep(1)
        # Ctrl+U clears keys that are in the prompt already.
        os.write(self.fd, b"\x15" + self.secret + b"\r")
        print(f"passphrase sent (try {self.tries})", file=sys.stderr)
        return False


def stop(pid, fd):
    # Ctrl+] leaves virsh console.
    try:
        os.write(fd, b"\x1d")
    except OSError:
        pass
    time.sleep(0.5)
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)


def main():
    uri, vm, mode, start, secret, mok_pw = parse_args()
    log = open(os.environ.get("CONSOLE_LOG", os.devnull), "ab")

    pid, fd = pty.fork()
    if pid == 0:
        cmd = ["start", vm, "--console"] if start else ["console", vm, "--force"]
        os.execvp("virsh", ["virsh", "-c", uri] + cmd)

    watch = Watch(fd, log, mode, start, secret, mok_pw)
    try:
        watch.run()
    finally:
        stop(pid, fd)
    sys.exit(watch.rc)


if __name__ == "__main__":
    main()
