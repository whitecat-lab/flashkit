# Third-Party Notices

`FlashKit` bundles or builds against several third-party tools and assets to support filesystems, image conversion, Windows media patching, compression, and DOS media creation.

Examples currently used by the project include:

- `wimlib-imagex`
- `qemu-img`
- `ntfs-3g` utilities such as `mkntfs`, `ntfsfix`, `ntfscp`, and `ntfscat`
- `e2fsprogs` utilities such as `mke2fs` and `debugfs`
- `xz`
- FreeDOS system files
- `UEFI:NTFS` image assets

These components remain under their respective upstream licenses.

This repository itself is licensed under GPL-3.0-or-later, but publishing or redistributing app bundles that include third-party binaries may require preserving upstream license texts, notices, and source-availability obligations for those bundled components.

Before distributing builds publicly, review the licenses and redistribution terms of all bundled helpers and assets.
