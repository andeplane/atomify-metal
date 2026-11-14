#!/usr/bin/env python3
"""Edit three actual screen recordings into a 24-second App Store preview.

ffmpeg honors the simulator's rotation metadata. The complete original screen
is preserved beneath a short caption band; no simulated product UI is added.
"""
import argparse
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont

CAPTIONS = [
    ("Explore the world atom by atom.", "Real simulations. Running on your device."),
    ("Watch the physics unfold.", "Live measurements beside the molecules."),
    ("Follow your curiosity.", "Discover flow, materials and molecular motion."),
]


def run(*args):
    subprocess.run(list(map(str, args)), check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("--ipad", action="store_true")
    args = p.parse_args()
    w, h = (1600, 1200) if args.ipad else (1920, 886)
    band = round(h * .18)
    clips = sorted((args.directory / "raw").glob("*.mov"))[:3]
    if len(clips) != 3:
        raise RuntimeError("Expected three recorded simulation clips")
    for i, (movie, (headline, detail)) in enumerate(zip(clips, CAPTIONS)):
        caption = Image.new("RGB", (w, band), (17, 17, 19))
        draw = ImageDraw.Draw(caption)
        draw.text((w * .04, band * .1), headline,
                  font=ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", round(w * .029), index=2),
                  fill=(248, 248, 250))
        draw.text((w * .04, band * .57), detail,
                  font=ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", round(w * .018), index=7),
                  fill=(177, 197, 220))
        caption_path = args.directory / "raw" / f"caption-{i}.png"
        caption.save(caption_path)
        # Letterbox the full screen inside the remaining canvas; do not crop UI.
        graph = (f"[0:v]fps=30,scale={w}:{h-band}:force_original_aspect_ratio=decrease,"
                 f"pad={w}:{h-band}:(ow-iw)/2:(oh-ih)/2:color=0x111113,setsar=1[v];"
                 f"[1:v][v]vstack=inputs=2,fade=t=in:st=0:d=0.18,fade=t=out:st=7.82:d=0.18[out]")
        run("ffmpeg", "-y", "-threads", "2", "-i", movie, "-loop", "1", "-i", caption_path,
            "-filter_complex_threads", "2", "-filter_complex", graph, "-map", "[out]",
            "-t", "8", "-r", "30", "-fps_mode", "cfr", "-an", "-c:v", "libx264", "-threads", "2", "-preset", "fast",
            "-profile:v", "high", "-level:v", "4.0", "-b:v", "11M", "-maxrate", "12M",
            "-bufsize", "24M", "-pix_fmt", "yuv420p", "-video_track_timescale", "30000",
            args.directory / "raw" / f"edited-{i}.mp4")
        print(f"Edited {movie.name}", flush=True)
    listing = args.directory / "raw" / "concat.txt"
    listing.write_text("".join(f"file 'edited-{i}.mp4'\n" for i in range(3)))
    output = args.directory / "Atomify-5.0-preview.mp4"
    run("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listing,
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-t", "24", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output)
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(output)])
    (args.directory / "preview-specification.json").write_bytes(probe)
    data = json.loads(probe)
    video = next(s for s in data["streams"] if s["codec_type"] == "video")
    assert (video["width"], video["height"]) == (w, h)
    assert video["r_frame_rate"] == "30/1"
    assert 15 <= float(data["format"]["duration"]) <= 30
    assert int(data["format"]["size"]) < 500_000_000
    print(output, flush=True)


if __name__ == "__main__":
    main()
