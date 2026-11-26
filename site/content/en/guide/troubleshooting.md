---
title: Troubleshooting
description: Common OM Photos problems and fixes: the Mac will not open the app, the camera Wi-Fi is not found, the photo list is empty, nothing happens over USB.
group: help
order: 7
---

## "OM Photos can't be opened"

This build is not signed with an Apple Developer ID. Go to **System Settings › Privacy & Security**, find OM Photos under Security and click **Open Anyway**. See [Install the Mac app](/en/guide/install-mac/) for details.

## The camera's Wi-Fi is not found

- Make sure the camera is showing the Device Connection QR code screen. Leaving that screen may turn the camera's Wi-Fi off.
- The network takes a few seconds to appear after the camera turns Wi-Fi on; OM Photos retries a few times.
- If you declined Location Services, macOS does not let apps read Wi-Fi names, so OM Photos cannot switch for you. Allow it in System Settings › Privacy & Security › Location Services, or join the camera's Wi-Fi from the menu bar and OM Photos connects right away.

## It did not switch back to my Wi-Fi

OM Photos first waits for macOS to rejoin your usual network, then tries to join the one you were on. If you are still not connected, pick your Wi-Fi from the menu bar.

## The photo list is empty

- With no photos on the card, it says "No photos or videos on the card".
- Check the filters at the top and in the sidebar, and set them back to All.

## Nothing happens over USB

- Make sure the camera is on and you chose Storage or MTP in the camera's USB mode menu. Charging or tethering modes do not show photos.
- Try another USB-C cable; some only charge.
- In Storage mode the card should also appear in the Finder sidebar.

## An import failed or stopped

If the camera's Wi-Fi drops, a file that was half downloaded starts over (the camera cannot resume). OM Photos retries once; files that still fail are listed with a Retry button. For many files, use USB-C.

## Still stuck?

Email [contact@jimmy-tools.com](mailto:contact@jimmy-tools.com) with your camera model, how you connected and the message you saw.
