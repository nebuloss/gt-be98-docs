# Buildroot M1 — first Buildroot-assembled hybrid .pkgtb (2026-06-05)

**Status: DONE (build + structural verification). NOT flashed — no device contact.**

M1 = produce the first `.pkgtb` assembled by **Buildroot** (`BR2_EXTERNAL` =
`gt-be98-buildroot`) where the merlin-built **bootfs is reused as-is** and the
**rootfs content comes from the known-good 0031 image** — proving the
Buildroot packaging pipeline end-to-end before any from-source migration.

## What was built

```
cd /home/guillaume/be98
git clone --branch 2026.02.2 --depth 1 file:///home/guillaume/be98/buildroot buildroot-m1   # clean clone
cd buildroot-m1
export BR2_DL_DIR=/home/guillaume/be98/buildroot/dl       # shared download cache
make BR2_EXTERNAL=/home/guillaume/be98/gt-be98-buildroot gt-be98_full_defconfig
make -j12
# -> output/images/GT-BE98_nand_squashfs.pkgtb
```

Everything is fetched by URL + sha256 (Buildroot idiom): the external toolchain
from a `gt-be98-toolchain` Release asset, the two proprietary blobs from
`gt-be98-packages` Release assets (`rootfs-0031`, `bootfs-0031` — see "Pending"
below), all other sources from public upstreams.

## Design choice: blob package, not rootfs-overlay

The 0031 rootfs squashfs is consumed as a **blob package**
(`gt-be98-rootfs`, fetched by URL+hash per the gt-be98-packages mechanism +
ARCHITECTURE.md blob policy), used **verbatim** by
`board/gt-be98/post-image-full.sh` as `rootfs.squashfs`. A rootfs-overlay was
rejected because:

- unpacking + re-squashing 61 MB of proprietary userspace loses byte-identity
  (timestamps, inode order, xattrs) and makes parity unverifiable at a glance;
- the ASUS rootfs has `/etc`, `/var`, `/root` as tmpfs symlinks and an empty
  devtmpfs `/dev`, which fights Buildroot's target-finalize/skeleton;
- the blob keeps the recipe tree blob-free (its `.gitignore` enforces this) and
  the binary in a Release asset, per ARCHITECTURE.md.

Buildroot's own skeleton/busybox is **absent from the shipped image**: the
defconfig sets `BR2_INIT_NONE` + no busybox + `BR2_SYSTEM_BIN_SH_NONE`, and the
throwaway Buildroot rootfs is replaced wholesale by the blob before bundling.

## Provenance fix: blobs re-derived from the VALIDATED artifact

The previous 1.0 blobs (packaged 2026-06-04 from the vendor tree's
`targets/96813GW/`) turned out to be **stale**: their bootfs differs from the
validated 0031 image in actual content (different `uboot` and `kernel` inner
hashes, not just FIT timestamps), and the rootfs differs too — the vendor tree
keeps moving as later patches (0032+) are built.

Fix: blobs are now extracted **from the validated 0031 .pkgtb itself**
(`gt-be98-firmware/artifacts-0031/GT-BE98_3006_102.6_0_nand_squashfs.pkgtb`,
sha256 `a7dcd0c14669eb363be775fc208f1f73098226723e420a3e3408095b1e98fa01`, the
image flashed and running on the device) with the new
`gt-be98-packages/scripts/extract-pkgtb.sh` (dumpimage-based; locates the
bootfs/rootfs FIT images by type, verifies nothing by offset guessing), then
packaged reproducibly with the existing `scripts/package-blob.sh`:

| Blob | Version | Content sha256 (inside) | Asset sha256 (tar.gz) |
|---|---|---|---|
| gt-be98-rootfs (`rootfs.img`, squashfs v4 xz 128K, 64036864 B) | 0031 | `dfbf98b4d3a474887ad029e9e6347da081f013e615a607f4f083bb2f3ab28d2c` | `26fa4540015346484e89d355a4fa608dce05b5085a657cf55d4c7dfab4754d5b` |
| gt-be98-bootfs (`bcm96813GW_uboot_linux.itb`, 13328136 B) | 0031 | `81f38fe09f602c15cd6d0625cf779f317129c25702ef8b338baeef29d23dec73` | `957671977c2f93bb51d045473219fba08cb1375ea41e0700dd3e6cb6bf776560` |

Both content hashes match the sha256 hash nodes recorded inside the 0031 FIT —
extraction is self-verifying.

## Verification of the produced image

TBD-VERIFICATION

## Pending / next

1. **User action: upload the two Release assets** (no gh CLI/API token on this
   host). Tarballs are staged in `gt-be98-packages/output/`:
   ```
   gh release create rootfs-0031 output/gt-be98-rootfs-0031.tar.gz --repo nebuloss/gt-be98-packages -t "gt-be98-rootfs 0031" -n "rootfs squashfs extracted from the validated 0031 pkgtb (a7dcd0c1…fa01)"
   gh release create bootfs-0031 output/gt-be98-bootfs-0031.tar.gz --repo nebuloss/gt-be98-packages -t "gt-be98-bootfs 0031" -n "bootfs .itb extracted from the validated 0031 pkgtb (a7dcd0c1…fa01)"
   ```
   Until then, clean-clone builds need the tarballs pre-seeded in `$BR2_DL_DIR`
   (`dl/gt-be98-rootfs/`, `dl/gt-be98-bootfs/`). This build used pre-seeded
   copies; hashes are enforced by the recipes either way. The old `rootfs-1.0` /
   `bootfs-1.0` releases should be considered deprecated (stale provenance).
2. **M2 candidates:** boot-test the M1 image on the device (separate decision —
   M1 explicitly does not flash); start replacing rootfs content pieces with
   Buildroot-built packages (the `gt-be98_defconfig` Buildroot-userspace track);
   kernel/ATF/U-Boot from source remains deferred (Step 2b).
