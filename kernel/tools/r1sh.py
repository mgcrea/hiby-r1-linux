"""Run shell commands on the R1 over the mainline kernel's USB serial gadget.

usage: python3 r1sh.py 'command' ...      (each runs in turn; output printed)
       python3 r1sh.py --port               print the R1's serial port, or fail

Finds the R1's port by its USB product name ("Gadget Serial", the kernel's
g_serial) in the IORegistry, since other boards (an ESP32...) also show up
as /dev/cu.usbmodem*. Sends each command followed by an end marker and
prints what comes back until the marker (or a timeout).
"""
import os, select, subprocess, sys, termios, time, tty


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
for cmd in sys.argv[1:]:
    os.write(fd, cmd.encode() + b"; echo R1SH_END_$?\r")
    out = read_until(b"R1SH_END_", 60)
    out += read_until(b"\n", 1)
    text = out.decode(errors="replace").replace("\r", "")
    body, _, status = text.partition("R1SH_END_")
    print(body.strip("\n"))
    status = (status.split() or [""])[0]
    if status not in ("", "0"):
        print(f"[exit {status}]")
