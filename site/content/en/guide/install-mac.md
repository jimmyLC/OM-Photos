---
title: Install the Mac app and open it the first time
description: Download OM Photos for Mac, drag it to Applications, and allow it in Privacy & Security the first time you open it.
group: start
order: 1
---

OM Photos is a free Mac app that imports photos and videos from OM System and Olympus cameras. This guide covers installing it and opening it for the first time.

> The app's interface is in Traditional Chinese for now (English is planned). These guides give each button's Chinese label in parentheses.

## What you need

- A Mac running **macOS 27 or later** (Apple silicon or Intel).
- An OM System or Olympus camera with Wi-Fi or USB-C. OM Photos has been tested with the **OM-3**; other models that work with OI.Share / OM Image Share should work too.

## 1. Download and install

1. On the [download page](/en/download/), click "Download for Mac" to get `OM-Photos.dmg`.
2. Open the DMG and drag **OM Photos** into the Applications folder next to it.
3. Eject the DMG.

## 2. Open it the first time

This build is not signed with an Apple Developer ID, so the first time you open it macOS says it cannot be opened or cannot verify the developer. That is expected; do this once:

1. Double-click OM Photos in Applications and click "Done" or "Cancel" on the warning.
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to "OM Photos was blocked to protect your Mac", click **Open Anyway**, then confirm with your password or Touch ID.

From then on it opens like any other app.

## 3. Permissions it asks for

| Permission | When | Why |
|---|---|---|
| Camera | First QR scan | Reads the QR code on the camera screen with your Mac's camera |
| Location Services | First automatic Wi-Fi switch | macOS requires it to read Wi-Fi names; OM Photos does not record your location |

Saying no is fine: you can type the Wi-Fi details instead of scanning, and switch Wi-Fi yourself from the menu bar.

## Next

- Over Wi-Fi: [Pair your camera and connect over Wi-Fi](/en/guide/pair-wifi/)
- With a cable: [Connect your camera with USB-C](/en/guide/usb/)
