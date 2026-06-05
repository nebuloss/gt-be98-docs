# GT-BE98 flash journal

One entry per flash: date, image sha256, slot, metadata before/after, gate
results, verdict, commit decision. Baseline entries record device state between
flashes. Maintained by the autonomous Buildroot-takeover agent.

Conventions: slot numbering follows `bcm_bootstate` ("First"/"Second" partition
= slot 1/2); metadata read via `bcm_bootstate` (no args) +
`/proc/bootstate/{active_image,reset_reason,old_reset_reason,boot_failed_count}`.

---

## 2026-06-05 — BASELINE (Phase 0 audit, no device writes)

**Device state (verified live ~20:55 UTC):**

- Running image: custom **0031** (merlin behnd 5.04 + patches 0001–0031),
  kernel `4.19.294 #1 SMP PREEMPT Thu Jun 4 10:39:22 UTC 2026`,
  image_version `5044p3GW1561435(BSPv1W13)`, flashed 2026-06-05 ~18:00 per
  `plans/go-no-go-flash-report.md` §9.
- Slot metadata: `active_image=1`, valid=1,2, seq=21,20, **committed = slot 1**
  (`BOOT_SET_PART1_IMAGE`, Booted/Reboot Partition: First).
  `reset_reason=34`, `boot_failed_count=0`. Uptime ~4h45 — consistent with the
  18:00 flash reboot.
- Slot 1 = validated custom 0031 (known-good anchor). Slot 2 = pre-0031 stock
  image (valid, seq 20, uncommitted).
- SSH :2222 key-auth works (wired). jffs mounted rw (ubifs vol 13).
  `jffs2_scripts=1`.

**Live user networks (pre-flash reference for the validation gate):**

| SSID | Bridge/VLAN | BSSes (hostapd, webui-go-managed) |
|---|---|---|
| Ramondia | br20 | wl0.1, wl1.1, wl3.2 |
| Pagoa | br30 | wl3.3 |
| DEV-SCEP | br50 | wl0.2, wl1.2, wl3.5 |

NOTE: the `test` net (mentioned in go-no-go §6/§8) **no longer exists** —
3 user nets is current reality. Additional vifs wl0.3/wl1.3/wl2.1/wl3.6 sit in
br20 and wl3.4/br70 exists with no hostapd (leftover plumbing, hex-string base
SSIDs on the primary wlX ifaces are normal). 4 stock hostapd instances
(`/tmp/wlX_hapd.conf`, rc-generated) + 7 webui-go hostapd instances. 0 clients
associated at snapshot time (evening).

**Backups (all under `~/be98/device-backups/2026-06-05/`):**
nvram-show.txt (182K), jffs-backup.tar.gz (5.4M), ps-w.txt, wifi-snapshot.txt,
dmesg-tail.txt, identity.txt, host-archived-images.txt. Host-archived flashable
images: stock pkgtb `a6f092ca…0fc5e1`, custom 0031 pkgtb `a7dcd0c1…fa01`
(both in `gt-be98-firmware/`).

**Facts that shape the flash harness (from go-no-go §9, live-observed):**

1. **ASUS init self-commits a successfully-booted ONCE-trial** (observed
   committed 2→1 with no operator action). ⇒ Layer-B dead-man must REPAIR the
   commit flags (re-commit the good slot) before its forced reboot; ONCE alone
   does not protect against "boots + self-commits + SSH broken".
2. `hnd-write` auto-commits the freshly written slot (exit 99 = normal) ⇒
   commit flags must be flipped back to the good slot immediately after
   flashing, before any reboot.
3. envrams still runs despite patch 0026 (started outside rc); patch 0032
   (rootfs wrapper at the real start site) exists in gt-be98-firmware,
   **built (artifacts-0032) but UNFLASHED/UNVALIDATED** — candidate content for
   the Buildroot mutation track, not a baseline.

**Verdict:** device healthy on committed known-good slot 1; safe to proceed to
Phase 1 (harness implementation, no reboots).
