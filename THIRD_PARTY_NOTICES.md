# Third-Party Notices

`FlashKit` commits helper binaries and runtime assets directly under `Resources/`. This file is a shipped-components map for the public repository, not a substitute for upstream license texts.

The generated helper inventory lives at:

- `Resources/Helpers/bundled-helpers.txt`

That manifest is the exact file-level inventory used when the helper bundle is staged. The sections below map those committed payload families back to their upstream projects and license families.

## Helper Tool Payloads

### wimlib

- Shipped items:
  - `Resources/Helpers/wimlib-imagex`
  - `Resources/Helpers/lib/libwim.15.dylib`
- Upstream project: `wimlib` by Eric Biggers
- License family: GPL-3.0-or-later
- Upstream source / homepage:
  - `https://wimlib.net/`
  - `https://github.com/ebiggers/wimlib`

### QEMU

- Shipped items:
  - `Resources/Helpers/qemu-img`
- Upstream project: QEMU
- License family: mixed LGPL-2.1-or-later / GPL-2.0-or-later components
- Upstream source / homepage:
  - `https://www.qemu.org/`
  - `https://www.qemu.org/license/`

### NTFS-3G / ntfsprogs

- Shipped items:
  - `Resources/Helpers/mkntfs`
  - `Resources/Helpers/ntfsfix`
  - `Resources/Helpers/ntfscp`
  - `Resources/Helpers/ntfscat`
  - `Resources/Helpers/lib/libntfs-3g.89.dylib`
- Upstream project: NTFS-3G / ntfsprogs
- License family: GPL-2.0-or-later
- Upstream source / homepage:
  - `https://github.com/tuxera/ntfs-3g`
  - `https://github.com/tuxera/ntfs-3g/wiki`

### e2fsprogs

- Shipped items:
  - `Resources/Helpers/mke2fs`
  - `Resources/Helpers/debugfs`
  - `Resources/Helpers/lib/libext2fs.2.1.dylib`
  - `Resources/Helpers/lib/libe2p.2.1.dylib`
  - `Resources/Helpers/lib/libcom_err.1.1.dylib`
  - `Resources/Helpers/lib/libss.1.0.dylib`
- Upstream project: e2fsprogs
- License family: mixed GPL-2.0-or-later / LGPL-family components
- Upstream source / homepage:
  - `https://e2fsprogs.sourceforge.net/`
  - `https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git`

### XZ Utils

- Shipped items:
  - `Resources/Helpers/xz`
  - `Resources/Helpers/lib/liblzma.5.dylib`
- Upstream project: XZ Utils
- License family: mixed 0BSD / LGPL-2.1-or-later / GPL-2.0-or-later / GPL-3.0-or-later upstream components
- Upstream source / homepage:
  - `https://tukaani.org/xz/`
  - `https://github.com/tukaani-project/xz`

## Repo-Local Helper Sources

### NTFS Population Helper

- Shipped items:
  - `Resources/Helpers/ntfs-populate-helper`
- Source used for this repo build:
  - `script/helper_sources/ntfs-populate-helper.c`
- Upstream/library dependency:
  - links against the bundled NTFS-3G libraries listed above
- License family:
  - repo-local source under this repository's GPL-3.0-or-later terms
  - plus the linked upstream NTFS-3G terms

### FreeDOS Boot Helper and Vendored `ms-sys` Source

- Shipped items:
  - `Resources/Helpers/freedos-boot-helper`
- Source used for this repo build:
  - `script/helper_sources/freedos-boot-helper.c`
  - `script/helper_sources/ms-sys/`
- Upstream project:
  - `ms-sys` (vendored helper source fragments)
- License family:
  - GPL-2.0-or-later for the vendored `ms-sys` source
  - repo-local wrapper code under this repository's GPL-3.0-or-later terms
- Source / reference:
  - vendored in this repo under `script/helper_sources/ms-sys/`

## Runtime Asset Payloads

### FreeDOS Runtime Files

- Shipped items:
  - `Resources/FreeDOS/*`
- Upstream project: FreeDOS
- License family: mixed FreeDOS package licenses, primarily GPL-family and other free-software licenses depending on the component
- Upstream source / homepage:
  - `https://www.freedos.org/`
- Notes:
  - this repository ships selected runtime files, not the complete FreeDOS distribution tree
  - individual files may carry more specific upstream notices than this summary

### UEFI:NTFS Image

- Shipped items:
  - `Resources/UEFI/uefi-ntfs.img`
- Upstream project: UEFI:NTFS / Rufus ecosystem
- License family: GPL-2.0
- Upstream source / homepage:
  - `https://github.com/pbatard/uefi-ntfs`

## Transitive Shared Libraries

- Shipped items:
  - `Resources/Helpers/lib/*`
- What they are:
  - transitive dependency libraries copied into the helper bundle to keep the committed helper executables self-contained
  - examples include `glib`, `gnutls`, `nettle`, `p11-kit`, `tasn1`, `unistring`, `iconv`, `ffi`, `gmp`, `pcre2`, `zlib`, `zstd`, `uuid`, `blkid`, and related support libraries
- Source / traceability:
  - these dependencies are enumerated in `Resources/Helpers/bundled-helpers.txt`
  - they arrive as transitive dependencies of the principal upstream helper projects listed above
- License family:
  - varies by library; review each upstream project before redistributing a public app bundle

## Repository License vs. Bundled Payloads

This repository is licensed under GPL-3.0-or-later. That repository-level license does not erase or replace the upstream license obligations attached to bundled helpers, vendored source, or runtime assets.

Before redistributing built app bundles publicly, review:

- the repository `LICENSE`
- the helper inventory in `Resources/Helpers/bundled-helpers.txt`
- the upstream license texts and notices for every bundled project family listed above
