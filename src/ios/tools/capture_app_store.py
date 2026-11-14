#!/usr/bin/env python3
"""Capture real iPhone/iPad UI and footage; build App Store artwork.

Requires Pillow, ffmpeg, a booted landscape simulator and the Release app.
Outputs are deliberately outside tracked source, under build/app-store/5.0.
"""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
SHOTS = [
    ("gas_hydrates", "A universe beneath the surface.", "Explore atoms and molecules in real time.", "", 8),
    ("singlewater", "Get to know a molecule.", "Watch water move. See its geometry change.", "dashboard", 6),
    ("flow_pois", "See physics in motion.", "Explore flow, friction and diffusion, atom by atom.", "", 8),
    ("ice_crystal", "Discover the structure of ice.", "Turn, zoom and explore a three-dimensional crystal.", "", 8),
    ("sica_sheet", "Explore a world of materials.", "From molecular bonds to nanoscale structures.", "", 8),
    ("singlewater", "Follow your curiosity.", "Choose a simulation from the built-in library.", "gallery", 4),
]


def run(*args, check=True):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True, text=True)


def artwork(raw, output, title, subtitle):
    screenshot = Image.open(raw).convert("RGB")
    w, h = screenshot.size
    if w <= h:
        # simctl retains the iPad's physical portrait framebuffer even when
        # UIKit is landscape. Rotate the entire screen, never crop its UI.
        screenshot = screenshot.transpose(Image.Transpose.ROTATE_90)
        screenshot.save(raw)
        w, h = screenshot.size
    canvas = Image.new("RGB", (w, h), (17, 17, 19))
    draw = ImageDraw.Draw(canvas)
    pad = round(w * .045)
    title_font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", round(w * .033), index=2)
    subtitle_font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", round(w * .016), index=7)
    if draw.textbbox((0, 0), title, font=title_font)[2] > w - pad * 2:
        raise RuntimeError(f"Headline exceeds artwork: {title}")
    draw.text((pad, round(h * .025)), title, font=title_font, fill=(248, 248, 250))
    draw.text((pad, round(h * .025) + round(w * .047)), subtitle,
              font=subtitle_font, fill=(177, 197, 220))
    # Preserve the full screen, including every control, with no simulated UI.
    available = round(h * .77)
    scaled = screenshot.resize((round(w * available / h), available), Image.Resampling.LANCZOS)
    x, y = (w - scaled.width) // 2, h - available - round(h * .025)
    canvas.paste(scaled, (x, y))
    draw.rounded_rectangle((x - 1, y - 1, x + scaled.width, y + scaled.height), radius=12,
                           outline=(57, 59, 65), width=2)
    canvas.save(output)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True)
    p.add_argument("--family", choices=["iphone", "ipad"], required=True)
    p.add_argument("--directory", help="Output subdirectory, e.g. iphone-medium")
    p.add_argument("--app", type=Path, default=ROOT / "build/ios-sim/Build/Products/Release-iphonesimulator/Atomify.app")
    p.add_argument("--bundle", default="no.uio.atomify.dev")
    p.add_argument("--video", action="store_true")
    args = p.parse_args()
    output = ROOT / "build/app-store/5.0" / (args.directory or args.family)
    output.mkdir(parents=True, exist_ok=True)
    raw = output / "raw"
    raw.mkdir(exist_ok=True)
    run("xcrun", "simctl", "install", args.device, args.app)
    run("xcrun", "simctl", "status_bar", args.device, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100")
    manifest = []
    for i, (example, title, subtitle, panel, wait) in enumerate(SHOTS, 1):
        run("xcrun", "simctl", "terminate", args.device, args.bundle, check=False)
        # Explicitly reset the capture keys on every launch.
        launch = ["xcrun", "simctl", "launch", args.device, args.bundle,
                  "-AtomifyCapture", "", "-AtomifyShowcase", example,
                  "-AtomifyPanel", panel if panel != "gallery" else "",
                  "-AtomifyGallery", "YES" if panel == "gallery" else "NO"]
        run(*launch)
        time.sleep(wait)
        name = f"{i:02d}-{example}"
        screen = raw / f"{name}.png"
        run("xcrun", "simctl", "io", args.device, "screenshot", screen)
        artwork(screen, output / f"{name}.png", title, subtitle)
        manifest.append({"file": f"{name}.png", "example": example, "headline": title,
                         "subtitle": subtitle, "panel": panel})
        print(f"Captured {args.family}/{name}", flush=True)
        if args.video and i <= 3:
            movie = raw / f"{name}.mov"
            recording = subprocess.Popen(["xcrun", "simctl", "io", args.device, "recordVideo",
                                          "--codec=h264", "--force", str(movie)],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            time.sleep(9)
            recording.send_signal(signal.SIGINT)
            _, error = recording.communicate(timeout=30)
            if recording.returncode:
                raise RuntimeError(error.decode())
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    run("xcrun", "simctl", "terminate", args.device, args.bundle, check=False)
    run("xcrun", "simctl", "status_bar", args.device, "clear")
    print(output, flush=True)


if __name__ == "__main__":
    main()
