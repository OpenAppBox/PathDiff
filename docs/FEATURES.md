# Everything PathDiff does

[← Back to PathDiff](../README.md)

## Comparing

- Every difference sorted into **modified**, **moved / renamed**, **missing** (only in the left folder) and **extra** (only in the right folder), with counts and sizes.
- **Move detection:** identical files are matched across any path, files that were moved *and* edited are still paired, and a renamed folder is reported as one move.
- An overview with a tile per kind of change, a Changes list grouped by kind, and the full folder tree.
- Each folder's own `.gitignore` is respected (nested files, negations, `.git/info/exclude`), plus your own ignore patterns.
- Bookkeeping files that macOS and Windows leave on drives (`._` files, `.Spotlight-V100`, `Thumbs.db`, `$RECYCLE.BIN` and more) are ignored automatically.
- Two ways to compare:
  - **Contents (byte by byte):** every file present on both sides is read until the first difference. Nothing is ever missed.
  - **Quick (size and date):** files with the same size and modification date count as identical without being read, allowing for the 2-second date rounding of FAT and exFAT drives. Best for large photo and video backups.
- Optional whitespace and line-ending insensitivity for text files.
- Items that can't be read (for example because of permissions) are reported, not silently shown as missing.
- Extracted downloads: when each folder only wraps one inner folder (`project-main/`, `project-2.1/`), PathDiff offers to compare those instead.

## Reviewing

- **Text:** side-by-side or unified layout, word-level highlights, syntax highlighting for about 25 languages, a minimap of every change, line numbers and collapsible unchanged regions.
- **Moved files** are compared with their counterpart, so you see what changed during the move.
- **Images:** side by side, swipe, onion skin, or a difference map with changed-pixel statistics, up to 16× zoom. JPEG, HEIC, PNG, GIF, TIFF, WebP, RAW, PDF, SVG and more. Photos are shown upright, as the camera recorded them.
- **Video and audio:** two players you can start, pause, rewind and line up together.
- **Details panel:** size and modification date (marking the newer copy), plus what the files say about themselves: dimensions, capture date, camera, lens, exposure, software and location for photos; duration, resolution, frame rate, codecs, bit rate and recording date for video and audio.
- **Checksums:** SHA-256 and MD5 of both files on request, with a match verdict.
- **Edit in place:** both sides become editors with syntax colors, and differences update as you type. Saving keeps each file's encoding, byte-order mark and line endings, and won't overwrite a file another app changed unless you confirm.

## Syncing

- Copy a single change block, a file, a folder or a whole selection, in either direction.
- **Sync** one way, as a full mirror, or **merge both ways** so each folder gets what only the other has, with the newer copy of a changed file replacing the older one.
- Every planned operation is listed before anything is written. Untick what you don't want, or copy the plan as text.
- **Apply Move** renames an item on one side so both folders match, without copying anything.
- **Undo** (⌘Z) for every operation, including a sync you stopped halfway.
- **Sync History** (⇧⌘H) logs every change PathDiff makes and keeps backups of what was overwritten, so a change can be reverted even after relaunching. Before reverting, it lists files that changed again since.
- **Safeguards:** removed items go to the Trash. The preview stays up to date as files change, PathDiff never overwrites a file or folder it didn't plan to replace, and folders it couldn't read are left untouched.

## Sharing

- Export a Markdown or CSV report of every difference.
- Export a `git apply`-compatible patch for the whole comparison, or copy the patch for one file.
- Open any folder present on both sides as its own comparison in a new window.

## Everyday

- Recent comparisons, and the last comparison reopens at launch.
- Drag folders from the Finder onto PathDiff.
- Open comparisons update on their own when files change.
- Light, dark or system appearance.
- 23 languages, chosen in Settings or following your Mac.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Choose left / right folder | ⌘O / ⇧⌘O |
| Changes list / folder tree | ⌘1 / ⌘2 |
| Refresh / stop scan | ⌘R / ⌘. |
| Swap folders | ⌥⌘S |
| Next / previous change | ⌥⌘↓ / ⌥⌘↑ |
| Next / previous changed file | ⌃⌘↓ / ⌃⌘↑ |
| Copy current change to right / left | ⌥⌘→ / ⌥⌘← |
| Copy selected items to right / left | ⇧⌥⌘→ / ⇧⌥⌘← |
| Sync | ⇧⌘Y |
| Side-by-side / unified diff | ⌃⌘1 / ⌃⌘2 |
| Edit file / save edits | ⌥⌘E / ⌘S |
| Sync History | ⇧⌘H |
| Export patch | ⌥⇧⌘P |
| Copy report as Markdown | ⌥⇧⌘C |
| Help | ⌘? |
