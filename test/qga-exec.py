"""Runs a shell command in a VM through the QEMU guest agent and prints its output.

Usage: python3 test/qga-exec.py QGA_SOCKET COMMAND
"""
import base64
import json
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(60)
sock.connect(sys.argv[1])
channel = sock.makefile("rw")


def call(command, **arguments):
    channel.write(json.dumps({"execute": command, "arguments": arguments}) + "\n")
    channel.flush()
    return json.loads(channel.readline())["return"]


pid = call("guest-exec", path="/bin/sh", arg=["-c", sys.argv[2]], **{"capture-output": True})["pid"]
while not (status := call("guest-exec-status", pid=pid))["exited"]:
    time.sleep(1)
for key in ("out-data", "err-data"):
    sys.stdout.write(base64.b64decode(status.get(key, "")).decode(errors="replace"))
sys.exit(status.get("exitcode", 1))
