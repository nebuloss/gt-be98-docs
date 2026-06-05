# Patch 0031 — dropbear failsafe: always-on SSH listener on :2222

> The **inverse** of the 0024/0026–0030 gates. Those patches turn ASUS daemons *off*
> by default behind nvram flags; this one makes the only admin path — dropbear SSH on
> `:2222`, no serial console on this AP — **impossible to turn off by nvram**. It is the
> safety net for the whole gating campaign: if any nvram experiment (or a wiped/corrupt
> nvram) leaves `sshd_enable=0` or `sshd_port` garbage, the box still answers on `:2222`.
>
> All claims below are **[P] per-source** (RE of `release/src/router/rc/` in
> asuswrt-merlin.ng behnd 5.04, SDK src-rt-5.04behnd.4916). No live testing in this
> task; the build + on-device validation is the orchestrator's Stage 3/4.

## What gates dropbear today (RE findings, all [P])

- `rc/ssh.c:start_sshd()` is the **single launch funnel**. Stock logic:
  1. if `sshd_port` outside 1..65535 → `sshd_enable=0` + reset port to default;
  2. `if (!nvram_get_int("sshd_enable")) return 0;` ← **the brick vector**;
  3. if not pid 1 → `notify_rc("start_sshd")` (init re-runs it) ;
  4. writes `/root/.ssh/authorized_keys` from `sshd_authkeys`, ensures host keys
     (`check_host_keys()` → `/jffs/.ssh/dropbear_*_host_key`, symlinked into
     `/etc/dropbear/`), then `_eval()`s
     `dropbear -p <sshd_port> [-s] [-W <sshd_rwb>] (-a | -j -k)`.
- Boot path: `start_services()` calls `start_sshd()` under `#ifdef RTCONFIG_SSH`
  (`rc/services.c:13382`); `rc_service` handler restarts it on `start_sshd`/`restart_sshd`.
- **No watchdog respawn existed**: `rc/watchdog.c` had zero dropbear/sshd references.
  If dropbear dies (OOM, crash, `killall`), nothing brings it back until reboot.

## The patch (`patches/0031-dropbear-failsafe-always-on.patch`)

Two conceptual hunks, sshd/dropbear code paths only — zero changes to LAN/br0
bring-up, other daemons, or shared helpers.

### Hunk 1 — `rc/ssh.c:start_sshd()`: gate override + guaranteed `:2222`

Reuses the existing exec logic instead of duplicating it; a local `int failsafe` replaces
the early return:

- `if (!nvram_get_int("sshd_enable")) failsafe = 1;` — **was `return 0`**. The
  port-sanity block above still runs first; an insane `sshd_port` forces
  `sshd_enable=0`, which now lands in failsafe mode instead of "no sshd".
- Port selection: `failsafe ? 2222 : (sshd_port ?: 22)` — in failsafe mode the listen
  port is the **hardcoded literal 2222**, never read from nvram.
- Normal mode (`sshd_enable=1`): if `sshd_port != 2222`, a **second** `-p 2222`
  listener is appended (dropbear supports up to `DROPBEAR_MAX_PORTS = 10` `-p`
  options, `dropbear/src/sysoptions.h:91`; argv array extended by two slots, max
  occupancy 10 of 11 incl. terminator). If `sshd_port == 2222` the normal listener
  *is* the guarantee — no duplicate `-p`.
- Failsafe mode hardening: `-s` (disable password auth) and `-W <sshd_rwb>` are
  **skipped** (`!failsafe &&` guards), so a stray `sshd_pass=0` with empty
  `authorized_keys` cannot produce a listener nobody can log into, and a malformed
  `sshd_rwb` cannot make dropbear bail at startup. Host-key handling and
  `authorized_keys` writing are unchanged (they run in both modes).

Net effect: **every** `start_sshd()` invocation yields a dropbear listening on `:2222`,
for any combination of `sshd_enable` / `sshd_port` / `sshd_pass` / `sshd_rwb`.

### Hunk 2 — `rc/watchdog.c`: `sshd_check()` respawn

Imitates the `infosvr_check()` idiom exactly (same `pids()` process-existence check,
defined right after it, called from the same `watchdog(sig)` periodic handler, guarded
`#ifdef RTCONFIG_SSH` like the rc.h prototype):

```c
void sshd_check(void)
{
	if (!pids("dropbear"))
		start_sshd();
}
```

Watchdog is not pid 1, so `start_sshd()` takes its `notify_rc("start_sshd")` branch and
init performs the actual (failsafe-capable) launch — same indirection other `*_check`
respawns use. The call site sits next to `infosvr_check()` near the end of
`watchdog()` (runs every watchdog period, i.e. seconds, not minutes).

## Why it cannot be disabled by nvram

- The only stock nvram gate (`sshd_enable`) now *selects a mode* instead of aborting.
- The failsafe port is a compile-time literal `2222`; `sshd_port` is only honoured as
  an *additional* listener in normal mode.
- The watchdog check has **no nvram guard at all** (deliberately — the inverse of the
  0024/0028 pattern) and watchdog itself is core to the firmware (resets the HW
  watchdog) so it cannot be retired without bricking.
- Remaining off-switches are all *code-level*, not nvram: rebuild without the patch,
  or build with `RTCONFIG_SSH` unset (GT-BE98 profile has SSH=y).

## Interaction with normal start_sshd / stop_sshd

- `sshd_enable=1, sshd_port=2222` (current fleet config): byte-identical behaviour to
  stock — one listener, nvram options honoured, no extra process.
- `sshd_enable=1, sshd_port=N≠2222`: one dropbear process, two listeners (`:N` and
  `:2222`), nvram options honoured on both (dropbear options are per-daemon, not
  per-port).
- `sshd_enable=0` (or invalid `sshd_port`): hardened failsafe listener on `:2222` only.
- `service stop_sshd` still kills dropbear (unchanged) — but `sshd_check()` brings it
  back within one watchdog period. `restart_sshd` behaves as before.

## Limits / residual risks (all [P])

1. **`pids("dropbear")` can be satisfied by a session child**: if the master listener
   dies while an SSH session is open, the per-connection `dropbear` child keeps the
   name alive and the respawn waits until that session ends. Same blind spot as every
   neighbouring `*_check`; acceptable.
2. **Failsafe auth still depends on credentials existing**: password auth is forced on,
   but the password is the admin account's — a fully wiped nvram falls back to the
   factory default login. `authorized_keys` is still written from `sshd_authkeys` when
   present.
3. **`stop_sshd` window**: between an explicit stop and the next watchdog tick
   (seconds) there is no listener. Watchdog being killed *and* dropbear dying
   simultaneously would leave no respawner — but a dead watchdog also stops feeding
   the HW watchdog, which reboots the box into a state where `start_services()`
   relaunches both.
4. Firewall/iptables rules are out of scope: in AP mode the stock fw is permissive on
   br0; the patch does not (and must not) touch netfilter setup.

## Verification done in this task

- `patch -p1 -N -F 10 --dry-run` clean on the working vendor tree (0001–0027 applied).
- Real apply on **pristine HEAD** copies (`git show HEAD:…`) in a temp tree: both files
  patch cleanly (watchdog hunks at −3 offset, as expected vs 0024).
- Syntax harness: patched `start_sshd()` and `sshd_check()` compiled standalone with
  `gcc -fsyntax-only -Wall -Werror=implicit-function-declaration` (stubbed nvram/eval
  decls) — OK. Full in-context compile happens in the Stage 3 build.
- argv bounds re-checked by hand: worst case 10 of 11 slots used, NULL terminator intact.
