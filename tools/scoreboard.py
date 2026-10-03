"""Keep a high-score table for the camera breakout demo.

    python tools/scoreboard.py --player Alice

The FPGA's UART reaches the PC through the on-board PIC32, which relays it
over USB once it has seen '&'. The firmware stays quiet until the PC has
sent '&' and then any byte, because a byte that reaches the PIC32 before
relay mode jams its receiver until a power cycle. This script sends both.

Each game over ("OVER <score> <level>") goes into the table file with the
player's name, and the script prints the top ten. Change --player between
games by restarting the script. Leave relay mode with '%Ex' (hellofpga-prog
does that itself before it programs the board).
"""
import argparse
import json
import time
from pathlib import Path

import serial


def load(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return []


def show(scores, latest=None):
    print(f"\n{'':2}{'player':<16}{'score':>6}{'level':>6}  date")
    for i, s in enumerate(sorted(scores, key=lambda s: -s["score"])[:10]):
        mark = "*" if s is latest else " "
        print(f"{mark} {s['player']:<16}{s['score']:>6}{s['level']:>6}  {s['date']}")
    print()


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--player", default="player")
    p.add_argument("--file", type=Path, default=Path("scores.json"),
                   help="high-score table (default: scores.json)")
    p.add_argument("--port", default="/dev/ttyACM0")
    args = p.parse_args()

    scores = load(args.file)
    show(scores)
    with serial.Serial(args.port, 460800, timeout=0.5) as ser:
        ser.write(b"&")           # PIC32: relay mode; ignored if already in it
        time.sleep(0.1)
        ser.write(b"\n")          # the firmware starts talking after this byte
        buf = b""
        while True:
            buf += ser.read(256)
            *lines, buf = buf.split(b"\n")
            for raw in lines:
                line = raw.decode("ascii", "replace").strip().lstrip("&")
                if not line:
                    continue
                print(line)
                parts = line.split()
                if parts[0] == "OVER" and len(parts) == 3:
                    entry = {"player": args.player, "score": int(parts[1]),
                             "level": int(parts[2]),
                             "date": time.strftime("%Y-%m-%d %H:%M")}
                    scores.append(entry)
                    args.file.write_text(json.dumps(scores, indent=1) + "\n")
                    show(scores, entry)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
