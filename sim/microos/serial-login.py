"""Logs in as root on the guest's serial console and runs one shell command, printing what
it prints. run-host.sh uses it when ssh fails, to see inside the box, and to prove the
console takes root's password, which is what the password is for.

    python3 -I serial-login.py <serial socket> <root password> <command>

Exits 0 once the command's output is read, 1 if the console never offers a login or a
prompt within the time allowed.
"""
import socket
import sys
import time

sock_path, password, command = sys.argv[1], sys.argv[2], sys.argv[3]
marker = "SIM-SERIAL-DONE"

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(1.0)
seen = ""


def read_until(*needles, timeout=60):
    global seen
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(4096).decode("utf-8", "replace")
        except socket.timeout:
            continue
        if not chunk:
            break
        seen += chunk
        for n in needles:
            if n in seen:
                return n
    return None


def send(text):
    s.sendall(text.encode())


send("\r\n")
if read_until("login:", timeout=90) is None:
    print("serial: no login prompt")
    sys.exit(1)
seen = ""
send("root\r\n")
if read_until("Password:", timeout=30) is None:
    print("serial: no password prompt")
    sys.exit(1)
seen = ""
send(password + "\r\n")
if read_until("# ", "Login incorrect", timeout=60) != "# ":
    print("serial: root's password was refused")
    sys.exit(1)
print("serial: root logged in on the console")
seen = ""
send("stty cols 200; " + command + "; echo " + marker + "-$((1+1))\r\n")
read_until(marker + "-2", timeout=300)
body = seen.split(marker + "-2")[0]
# Drop the echoed command line itself.
print(body.split("\n", 1)[1] if "\n" in body else body)
send("exit\r\n")
