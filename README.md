# Photo clock for Kindle (KOReader plugin)

Full-screen clock for a jailbroken Kindle Paperwhite 12th gen (7", 1264×1680, 300 ppi).
A full-screen image changes every 10 minutes (one full flash, which also clears
e-ink ghosting), with the time and date in a box on top of it; the time updates
every minute without flashing. Optional "Upcoming meetings" list in the same box.

## Install

1. Plug the Kindle into your Mac.
2. Copy `photoclock.koplugin/` to `koreader/plugins/` on the Kindle.
3. Put source images in `originals/` and run:
   ```sh
   python3 -m venv .venv && .venv/bin/pip install pillow pillow-heif   # once
   .venv/bin/python prepare_images.py
   ```
   This trims scanned paper margins/captions, shrinks and grayscales each image into
   `photoclock/images/`. For a manual crop, add the file to `CROPS` in `prepare_images.py`.
   Then copy the `photoclock/` folder to the Kindle's root.
4. Eject, start KOReader, then open **Tools (wrench) → Photo clock**.

## Use

- **Tap**: next image
- **Long-press**: close
- **Meetings**: edit `photoclock/meetings.txt` (e.g. `09:30 Standup`). It is re-read every minute.
  Past meetings are hidden automatically.

## Keep it awake

If the Kindle sleeps, the clock stops. In KOReader, set
**Settings (gear) → Device → Power management → Autosuspend timeout** to off, or to a long time.
Keep the Kindle plugged in: the screen uses almost no power, but the CPU stays awake.
Turn Wi-Fi and the frontlight off to save power.

## Tweaks

Settings are at the top of `photoclock.koplugin/main.lua`: image interval, how often to flash, shuffle, 12/24h, clock box position.
