"""Runs one ansible-playbook command in a terminal, as the owner runs it on the phone, and
answers each passphrase prompt of server-unlock-arrays.yml from SIM_ANSWERS, a JSON object
keyed "<volume> on <host>". A prompt with no key gets Enter alone, which declines it. host/
three.sh uses it to drive the unlock play against the simulated three; pause asks only when
stdin is a terminal, so a pipe would prove nothing.

    SIM_ANSWERS='{"backup on three": "..."}' python3 -I play-prompts.py <command>...

Each answer is written only once the terminal's echo is off, so the transcript holds no
passphrase unless the play itself prints one, which is what the caller checks it for. The
transcript is printed with terminal escapes removed, from a terminal 400 columns wide so no
line the caller looks for is wrapped, then one line per prompt, in order,
"prompted: <volume> on <host>". Exits with the command's own status, or 1 if it outlasts
the time allowed.
"""
import fcntl
import json
import os
import pty
import re
import select
import struct
import sys
import termios
import time

answers = json.loads(os.environ.get("SIM_ANSWERS", "{}"))
prompt = re.compile(r"Passphrase for (\S+) on (\S+) \(Enter alone leaves it locked\)[^:]*:")
escapes = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[78=>]|\x1b\[?|\r")

pid, fd = pty.fork()
if pid == 0:
    # A wide terminal, so the repo's callback wraps none of the lines the caller greps for.
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 400, 0, 0))
    os.environ["COLUMNS"] = "400"
    os.execvp(sys.argv[1], sys.argv[1:])

text = ""
done = 0
prompted = []
deadline = time.time() + 900
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 1)
    if not ready:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    clean = escapes.sub("", chunk.decode("utf-8", "replace"))
    sys.stdout.write(clean)
    sys.stdout.flush()
    text += clean
    for m in prompt.finditer(text, done):
        key = f"{m.group(1)} on {m.group(2)}"
        prompted.append(key)
        done = m.end()
        # pause turns echo off before it reads; until then a reply would be echoed.
        for _ in range(100):
            if not termios.tcgetattr(fd)[3] & termios.ECHO:
                break
            time.sleep(0.05)
        os.write(fd, (answers.get(key, "") + "\r").encode())

rc = 1
try:
    _, status = os.waitpid(pid, os.WNOHANG if time.time() >= deadline else 0)
    if os.WIFEXITED(status):
        rc = os.WEXITSTATUS(status)
except ChildProcessError:
    pass
if time.time() >= deadline:
    os.kill(pid, 9)
    print("\nplay-prompts.py: the play outlasted the time allowed", file=sys.stderr)
for key in prompted:
    print(f"prompted: {key}")
sys.exit(rc)
