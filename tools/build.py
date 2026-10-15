"""Build the mod from your own copy of Street Legal Racing Redline.

    python tools/build.py "C:/path/to/Street Legal Racing Redline" [--upscaler path/to/realesrgan-ncnn-vulkan.exe]

Converts the SLRR drivers and pedestrians into mod/art, remasters their skins into PBR materials
(4x Real-ESRGAN upscale when --upscaler is given, a plain resize otherwise), renders the driver previews, and packs
everything into dist/slrr_drivers_and_pedestrians.zip, ready for BeamNG's mods folder.
Needs Python 3 with numpy, pillow and matplotlib (pip install numpy pillow matplotlib).
"""
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MOD = os.path.join(ROOT, "mod")


def run(script, *args):
    subprocess.check_call([sys.executable, os.path.join(HERE, script), *args])


def main():
    if len(sys.argv) < 2 or not os.path.isdir(os.path.join(sys.argv[1], "humans", "drivers")):
        sys.exit(__doc__)
    slrr = sys.argv[1]
    run("convert_drivers.py", slrr, MOD)
    run("convert_peds.py", slrr, MOD)
    run("convert_driver_walk.py", slrr)
    up = sys.argv[sys.argv.index("--upscaler") + 1] if "--upscaler" in sys.argv else None
    run("remaster_textures.py", *(["--upscaler", up] if up else []))
    run("make_tint_layers.py")       # clothing tint masks and the helmet, for setAppearance
    run("preview.py")
    out = os.path.join(ROOT, "dist", "slrr_drivers_and_pedestrians.zip")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(MOD):
            for f in files:
                full = os.path.join(folder, f)
                z.write(full, os.path.relpath(full, MOD).replace(os.sep, "/"))
    print("built", out)


if __name__ == "__main__":
    main()
