# Frequently asked questions

[← Back to PathDiff](../README.md)

**How is PathDiff different from the Finder or a simple diff tool?**
The Finder can't tell you what's different between two folders. Most diff tools compare paths, so a renamed folder looks like hundreds of deletions and additions. PathDiff recognizes moves, understands photos, videos and code, shows sizes, and syncs safely with a preview and undo.

**Is it safe to use on my only backup?**
Comparing never changes anything. Syncing lists every operation first, removes files only if you choose to mirror (and then to the Trash), and the whole sync can be undone. Merge Both Ways never removes anything. PathDiff never overwrites a file or folder it didn't plan to replace, and leaves folders it couldn't read alone instead of guessing.

**My backup drive has terabytes of video. Will it take forever?**
Choose Compare ▸ Compare Files By ▸ Quick (size and date). Files with the same size and modification date count as identical without being read; only the rest are compared byte by byte. PathDiff also remembers results, so the next comparison only checks what changed.

**Does it work with external drives and exFAT?**
Yes. Quick comparison allows for the 2-second date rounding of FAT and exFAT drives, and the bookkeeping files macOS and Windows leave on drives are ignored automatically.

**Do my folders need to be git repositories?**
No. PathDiff works with any two folders. If they happen to be git projects, it respects their `.gitignore` files and uses git's own records to skip files known to be unchanged.

**Can I verify a copy byte for byte?**
Yes. The default Contents comparison reads every file, and for any file you can calculate SHA-256 and MD5 checksums of both copies.

**Can I undo a sync after closing PathDiff?**
Yes. Sync History keeps backups of what each change overwrote (the newest 300 changes, up to 2 GB), so you can revert a change even after relaunching.

**Does PathDiff upload my files anywhere?**
No. It works entirely offline and collects no data. See the [privacy policy](../PRIVACY.md).

**What do I need?**
A Mac with Apple silicon running macOS 27 or later.

**Where do I get PathDiff?**
On the [Mac App Store]([APP_STORE_URL]). Updates arrive through the App Store too.

**How much does it cost?**
PathDiff is free to download and comes with a free week. After that, a yearly subscription keeps everything unlocked: 3 USD a year in the US, or the local equivalent. With Family Sharing, up to five family members can use one subscription. Cancel any time in your App Store account settings.

**What happens if my subscription ends?**
Comparing and syncing are locked until you subscribe again, but Sync History stays available, so you can still revert changes PathDiff made.

**The source code is here. Can I build it myself?**
Yes, the code is free software under the [GPL v3.0](../LICENSE), and you can build it with Xcode. We don't provide support for building or changing it, though; the Mac App Store version is the supported one, and buying it supports PathDiff's development.

**I found a bug, or I have an idea.**
Please [open an issue](https://github.com/OpenAppBox/PathDiff/issues/new/choose). See [Support](../SUPPORT.md) for what to include.
