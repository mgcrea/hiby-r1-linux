"""Run shell commands on the R1 over the mainline kernel's USB serial gadget.

usage: python3 r1sh.py 'command' ...      (each runs in turn; output printed)
       python3 r1sh.py --port               print the R1's serial port, or fail
       python3 r1sh.py --push LOCAL REMOTE  copy a file (gzip + base64 in chunks)

Finds the R1's port by its USB product name ("Gadget Serial", the kernel's
g_serial) in the IORegistry, since other boards (an ESP32...) also show up
as /dev/cu.usbmodem*. Sends each command followed by an end marker and
prints what comes back until the marker (or a timeout).
"""
import base64, gzip, os, select, subprocess, sys, termios, time, tty


def r1_port():
    """The /dev/cu.* node under the USB device named "Gadget Serial", if any."""
    tree = subprocess.run(["ioreg", "-r", "-c", "IOUSBHostDevice", "-l", "-w0"],
                          capture_output=True, text=True).stdout
    ours = False
    for line in tree.splitlines():
        if '"USB Product Name" = ' in line:
            ours = '"Gadget Serial' in line
        elif ours and '"IOCalloutDevice" = ' in line:
            return line.split('"IOCalloutDevice" = ')[1].strip().strip('"')
    return None


port = r1_port()
if sys.argv[1:] == ["--port"]:
    if not port:
        sys.exit(1)
    print(port)
    sys.exit(0)
if not port:
    sys.exit("no Gadget Serial port: is the R1 running the mainline kernel?")
fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
tty.setraw(fd)
attrs = termios.tcgetattr(fd)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(fd, termios.TCSANOW, attrs)


def read_until(marker, timeout):
    buf, end = b"", time.time() + timeout
    while marker not in buf and time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            buf += os.read(fd, 4096)
    return buf


os.write(fd, b"stty -echo 2>/dev/null; echo R1SH_READY\r")
read_until(b"R1SH_READY", 5)


def run(cmd, show=True):
    """Runs cmd and returns its exit status as a string ("" on a timeout)."""
    os.write(fd, cmd.encode() + b"; echo R1SH_END_$?\r")
    out = read_until(b"R1SH_END_", 60)
    out += read_until(b"\n", 1)
    text = out.decode(errors="replace").replace("\r", "")
    body, _, status = text.partition("R1SH_END_")
    status = (status.split() or [""])[0]
    if show:
        print(body.strip("\n"))
        if status not in ("", "0"):
            print(f"[exit {status}]")
    return status


if sys.argv[1:2] == ["--push"]:
    local, remote = sys.argv[2:4]
    data = base64.b64encode(gzip.compress(open(local, "rb").read())).decode()
    # Lines well under the tty's 4095-byte canonical limit.
    chunks = [data[i:i + 2048] for i in range(0, len(data), 2048)]
    run(f"rm -f {remote}.b64", show=False)
    for i, chunk in enumerate(chunks):
        if run(f"echo {chunk} >> {remote}.b64", show=False) != "0":
            sys.exit(f"push failed at chunk {i + 1} of {len(chunks)}")
    sys.exit(0 if run(f"base64 -d {remote}.b64 | gunzip > {remote} && rm {remote}.b64"
                      f" && chmod +x {remote}") == "0" else 1)
for cmd in sys.argv[1:]:
    run(cmd)
