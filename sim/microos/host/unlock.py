"""Runs one command on the simulated host over `ssh -tt`, as the owner would type it at a
terminal, and answers its prompts: sudo's for gavin's password, then systemd's for the
array's passphrase. run-host.sh uses it, through host/three.sh, to unlock three's array
with the command hosts/three/leap/README.md gives, so the simulation proves that command and
not a stand-in for it. Both prompts turn echo off, so the transcript it prints holds
neither secret.

    SIM_SUDO_PW=... SIM_LUKS_PW=... python3 -I unlock.py <ssh argument>... -- <command>

Exits with the command's own status, or 1 if a prompt never came within the time allowed.
"""
import os
import selectors
import subprocess
import sys
import time

args = sys.argv[1:]
split = args.index("--")
ssh, command = args[:split], " ".join(args[split + 1:])
answers = [
    ("password for", os.environ["SIM_SUDO_PW"]),
    ("passphrase", os.environ["SIM_LUKS_PW"]),
]

proc = subprocess.Popen(
    ["ssh", "-tt", *ssh, command],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)
assert proc.stdin is not None and proc.stdout is not None
sel = selectors.DefaultSelector()
sel.register(proc.stdout, selectors.EVENT_READ)
seen = ""
deadline = time.time() + 180
while time.time() < deadline:
    if not sel.select(timeout=1):
        if proc.poll() is not None:
            break
        continue
    chunk = os.read(proc.stdout.fileno(), 4096)
    if not chunk:
        break
    text = chunk.decode("utf-8", "replace")
    sys.stdout.write(text)
    sys.stdout.flush()
    seen += text
    # Each answer goes once, when its prompt has appeared since the last answer. sudo may
    # not ask, if it remembers this terminal; the passphrase is always asked.
    for i, (prompt, answer) in enumerate(answers):
        if prompt in seen.lower():
            proc.stdin.write((answer + "\n").encode())
            proc.stdin.flush()
            del answers[i]
            seen = ""
            break

try:
    rc = proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    rc = 1
if any(prompt == "passphrase" for prompt, _ in answers):
    print("\nunlock.py: the passphrase was never asked for", file=sys.stderr)
    rc = rc or 1
sys.exit(rc)
