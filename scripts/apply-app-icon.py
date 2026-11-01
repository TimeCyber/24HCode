# -*- coding: utf-8 -*-
"""Resize logo into Android mipmaps + HarmonyOS app/entry icons."""
from __future__ import print_function
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("Pillow required\n")
    sys.exit(1)

SRC = r"C:\Users\Administrator\.cursor\projects\d-androidproject-CodeAssit\assets\c__Users_Administrator_AppData_Roaming_Cursor_User_workspaceStorage_6d23518b067f4f807bdfc74508116940_images____________logo-fe5d6595-91ab-46bd-b9b0-04ce3c1c8a09.png"
ROOT = r"D:\androidproject\CodeAssit"

ANDROID_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

TARGETS = []

# Android (main mobile app)
for folder, size in ANDROID_SIZES.items():
    TARGETS.append(
        (
            os.path.join(
                ROOT,
                "mobile",
                "android",
                "app",
                "src",
                "main",
                "res",
                folder,
                "ic_launcher.png",
            ),
            size,
        )
    )

# HarmonyOS primary project
TARGETS.extend(
    [
        (
            os.path.join(
                ROOT,
                "mobile_ohos",
                "ohos",
                "AppScope",
                "resources",
                "base",
                "media",
                "app_icon.png",
            ),
            512,
        ),
        (
            os.path.join(
                ROOT,
                "mobile_ohos",
                "ohos",
                "entry",
                "src",
                "main",
                "resources",
                "base",
                "media",
                "icon.png",
            ),
            512,
        ),
        (
            os.path.join(
                ROOT,
                "mobile_ohos",
                "ohos",
                "entry",
                "src",
                "ohosTest",
                "resources",
                "base",
                "media",
                "icon.png",
            ),
            512,
        ),
    ]
)

# Also sync mobile/ohos scaffold if present
TARGETS.extend(
    [
        (
            os.path.join(
                ROOT,
                "mobile",
                "ohos",
                "AppScope",
                "resources",
                "base",
                "media",
                "app_icon.png",
            ),
            512,
        ),
        (
            os.path.join(
                ROOT,
                "mobile",
                "ohos",
                "entry",
                "src",
                "main",
                "resources",
                "base",
                "media",
                "icon.png",
            ),
            512,
        ),
        (
            os.path.join(
                ROOT,
                "mobile",
                "ohos",
                "entry",
                "src",
                "ohosTest",
                "resources",
                "base",
                "media",
                "icon.png",
            ),
            512,
        ),
    ]
)


def main():
    if not os.path.isfile(SRC):
        sys.stderr.write("source missing: %s\n" % SRC)
        sys.exit(1)
    src = Image.open(SRC).convert("RGBA")
    for path, size in TARGETS:
        parent = os.path.dirname(path)
        if not os.path.isdir(parent):
            print("skip (no dir):", path)
            continue
        out = src.resize((size, size), Image.Resampling.LANCZOS)
        # Android mipmaps historically RGB opaque; keep RGBA OK for PNG
        if out.mode != "RGBA":
            out = out.convert("RGBA")
        out.save(path, format="PNG", optimize=True)
        print("wrote", size, path)


if __name__ == "__main__":
    main()
