# Copy iPhone Media

Copies `.MOV`, `.JPG` and `.HEIC` files off a cabled iPhone into a folder on the PC.

Files are copied byte-for-byte — nothing is re-encoded, and the original capture
timestamps are kept.

---

## Prerequisites

**1. Apple drivers.** Install the **Apple Devices** app from the Microsoft Store:

<https://apps.microsoft.com/detail/9np83lwlpz9k?hl=en-US&gl=BG>

This is what makes the phone show up under `This PC` as a device. Without it
Windows sees the iPhone as a charging-only cable and the script has nothing to
read. You do not need to open or sign into the app — installing it is enough.

**2. Windows PowerShell.** Already on every Windows machine, nothing to install.

**3. The phone unlocked and trusted.** Plug it in, unlock the screen, and tap
**Trust This Computer** on the prompt. A locked phone lists as empty.

> **Must run on Windows.** The iPhone connects as an MTP device with no drive
> letter, so it only exists inside Windows Explorer's namespace. WSL cannot see
> the USB device at all, and `cp` / `robocopy` / `Get-ChildItem` cannot open the
> path. `copy-iphone-media.sh` is the bash equivalent, but it only works on
> ordinary folders (a mounted drive, an SD card) — not on the phone.

---

## Checking the path

Open Explorer and find your phone. The path looks like:

```
This PC\Apple iPhone\Internal Storage\202607_a
```

The folders are named by year and month — `202607_a` is July 2026.

---

## Running it

From a normal PowerShell window (no admin needed), in the folder holding the script:

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage\202607_a" "D:\Photos"
```

`-ExecutionPolicy Bypass` is needed because Windows blocks unsigned `.ps1` files
by default. It applies only to that one run and changes nothing system-wide.

Everything from 2026, keeping the folder structure:

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2026*"
```

See what would happen without copying anything:

```powershell
powershell -ExecutionPolicy Bypass -File Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2026*" -DryRun
```

---

## Options

| Option | Meaning |
| --- | --- |
| `-Extensions .MOV,.JPG,.HEIC` | Which file types to copy. Default is those three. |
| `-Folders "2026*"` | Which sub-folders to enter. Default is all of them. |
| `-Flat` | Put every file straight into the destination, no sub-folders. |
| `-Overwrite` | Replace a same-named file instead of keeping both. |
| `-DryRun` | List what would be copied, copy nothing. |

---

## Good to know

**Re-running is safe and cheap.** Files already copied are skipped, so an
interrupted transfer resumes where it left off. A same-named file with different
content is saved as `IMG_1234_1.JPG` rather than overwriting — repeated runs will
not pile up duplicates.

**If a folder reports no files, run it again.** The phone often lists a folder as
empty on first access and fills it in on a later read. This is normal and not an
error. Only if a folder stays empty across several runs are those photos actually
off the device — that happens with iCloud's *Optimize iPhone Storage*, which
leaves originals in the cloud. Switching to Settings → Photos → **Download and
Keep Originals** and letting the phone sync brings them back locally.

**Two files per edited photo.** `IMG_1234.JPG` is the original and
`IMG_E1234.JPG` is your edited version. Both are copied, so you keep the
untouched original too. That is why the file count runs higher than the number of
photos in your camera roll.

**Expect around 25 MB/s** over the cable — roughly 900 MB per minute.

---

## Troubleshooting

| Problem | Cause |
| --- | --- |
| `'Apple iPhone' not found under This PC` | Drivers missing (install Apple Devices), phone locked, or Trust not accepted. The script prints what it did find at that level. |
| `The argument ... does not exist` | Wrong filename. Browsers sometimes strip the hyphens on download — check the actual name in the folder. |
| Folder found but no files | See "run it again" above. |
| Files arrive as `.JPG` when you expect `.HEIC` | Phone is set to convert on transfer. Settings → Photos → Transfer to Mac or PC → **Keep Originals**. |
