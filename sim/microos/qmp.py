"""Sends human-monitor commands to a qemu QMP socket, one per argument, and prints each
reply. Used by run-late-disks.sh to hot-plug the simulated USB disks; run it with
python3 -I so nothing in the working directory is imported."""
import json
import socket
import sys


def main(path, commands):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    stream = sock.makefile("rw")
    json.loads(stream.readline())  # the greeting
    for request in [{"execute": "qmp_capabilities"}] + [
        {"execute": "human-monitor-command", "arguments": {"command-line": c}}
        for c in commands
    ]:
        stream.write(json.dumps(request) + "\n")
        stream.flush()
        while True:
            reply = json.loads(stream.readline())
            if "event" not in reply:
                break
        print(request.get("arguments", {}).get("command-line", request["execute"]), "->", reply)
        if "error" in reply:
            sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
