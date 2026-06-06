# Patch 0032 — envrams : gate du vrai site de lancement (wrapper rootfs)

Statut : patch écrit + build validé (2026-06-05). NON flashé.

## Problème

Le patch 0026 (`envrams-disable-by-default`) ajoute un gate
`nvram envrams_enable=1` dans `start_envrams()` de
`release/src/router/rc/ate.c`. Pourtant, sur l'image custom 0031 en service
(slot 1), envrams tourne toujours :

```
# ps w | grep envrams          (routeur live, lecture seule)
 4569 admin     2204 S    /usr/sbin/envrams
# cat /proc/4569/stat → PPID=1 (daemonisé), start ~116 s après boot,
#   PID juste après udhcpc_lan (4530), ntp (4532), disk_monitor (4549)
#   → en plein dans la séquence de démarrage des daemons rc
# nvram get envrams_enable → (vide)
```

## RE trail — qui lance envrams ?

Évidence [V] = vérifié sur le routeur live (image 0031), [P] = prouvé dans
les sources/objets vendor (merlin behnd 5.04, SDK src-rt-5.04behnd.4916).

1. [V] Aucun script d'init Broadcom ne lance envrams en mode normal :
   `grep -rl envrams /etc/init.d /rom/etc/init.d /etc/rc3.d /rom/etc/rc3.d`
   → seulement `hndmfg.sh` (S39), qui ne le lance **qu'en mode
   manufacturing** (`mfg_nvram_mode=1` côté bootloader). `hndnvram.sh` (S40)
   ne le référence pas. `/etc/inittab` vide.
2. [V] Scan de tous les binaires du rootfs live (`strings | grep envrams`) :
   seuls binaires contenant une commande de lancement :
   - `/sbin/rc`     : `"/usr/sbin/envrams >/dev/null"`
   - `/usr/sbin/httpd` : `"/usr/sbin/envrams &> /dev/null"`
3. [P] **Le gate 0026 n'a jamais été compilé.** `rc/Makefile` (l.2151) :
   ```make
   ifneq ($(wildcard ./prebuild/ate.o),)
   ate.o:
       @-cp -f ./prebuild/ate.o .
   ```
   Pour GT-BE98, `rc/prebuild/GT-BE98/ate.o` (closed-source, identique au
   `prebuild/ate.o` copié à chaque build) fournit `start_envrams` /
   `stop_envrams` / `chk_envrams_proc` — `ate.c` (patché par 0026) n'est
   jamais compilé. Preuve dans l'artefact : `strings fs.install/sbin/rc`
   contient `"/usr/sbin/envrams >/dev/null"` mais **pas** `envrams_enable`.
4. [P] Chemin de lancement au boot, via les relocations des prebuilts :
   `init.c sysinit()` (l.25707) → `init_asusctrl()` [T dans
   `prebuild/GT-BE98/ate-broadcom.o`] ; dans ce même objet,
   `is_envram_empty`, `deconfig_nvram_envram` et
   `asus_ctrl_envram_write.isra.0` ont des relocations vers
   `start_envrams` (idem `envram_dump_factory_data` dans `dsl_fb.o`).
   Le code asusctrl (SKU/contrôle ASUS) appelle `start_envrams()` prebuilt
   et non gaté pendant l'init de rc — cohérent avec la fenêtre de démarrage
   observée [V].
5. [P] Site de relance à la demande : la chaîne dans httpd vient du prebuilt
   closed-source `release/src/router/httpd/prebuild/GT-BE98/web_hook.o`
   (zéro hit `grep envram` dans les .c de httpd) :
   ```
   $ strings web_hook.o | grep -A3 'envrams &>'
   /usr/sbin/envrams &> /dev/null
   /usr/sbin/envram get wl0_dummy ...
   $ nm web_hook.o | grep -i envram → T sdk7114_envram_get_int
   ```
   → les handlers webui font `system("/usr/sbin/envrams &> /dev/null")`
   avant `envram get` : httpd respawne envrams dès qu'une page lit une
   variable envram. Le webui étant notre plan de contrôle, ce chemin est
   systématiquement sollicité.
6. [P] Vérifié aussi : la seule règle d'install du binaire pour GT-BE98
   (HND_ROUTER_BE_4916) est `envram_bin-install` dans
   `release/src/router/Makefile` (l'autre règle,
   `envram_bin/envram_arm_7114`, pointe sur un répertoire inexistant →
   jamais exécutée, sinon le build échouerait).

Conclusion : les deux sites de lancement réels (rc `ate.o`/`ate-broadcom.o`
et httpd `web_hook.o`) sont des **blobs binaires non patchables en texte**.
On gate donc au niveau du rootfs, à l'install du binaire.

## Design du gate (0032)

`release/src/router/Makefile`, règle `envram_bin-install`, branche
`HND_ROUTER_BE_4916` (la nôtre) :

- le vrai daemon prébuilt est installé en **`/usr/sbin/envrams.real`** ;
- **`/usr/sbin/envrams`** devient un wrapper `/bin/sh` généré par la règle :

```sh
#!/bin/sh
# Fork GT-BE98: envrams (remote NVRAM service, TCP 5152) gated, default off.
# Enable with: nvram set envrams_enable=1 (bootloader mfg mode bypasses).
[ -n "$(/bin/pidof envrams.real 2>/dev/null)" ] && exit 0
[ "$(/bin/nvram get envrams_enable 2>/dev/null)" = "1" ] && exec /usr/sbin/envrams.real "$@"
[ -e /proc/environment/mfg_nvram_mode ] && exec /usr/sbin/envrams.real "$@"
[ -e /proc/brcm/blxparms/mfg_nvram_mode ] && exec /usr/sbin/envrams.real "$@"
exit 0
```

Choix et raisons :

- **Default OFF** : flag absent / nvram non lisible / valeur ≠ 1 → exit 0,
  le daemon ne démarre jamais. Tous les sites de lancement (rc prebuilt,
  httpd web_hook.o, hndmfg.sh, tout futur appelant) passent par ce chemin.
- **Flag `envrams_enable=1`** : même flag que 0026 → une seule commande de
  réactivation, sans reflash. `nvram` est disponible dans le contexte des
  appelants réels (httpd et rc init tournent après S40/hndnvram,
  `/bin/nvram` présent sur l'image [V]) — pas besoin d'un fichier /jffs.
- **Bypass mode manufacturing** : en mfg (`mfg_nvram_mode=1` via bootloader,
  fichiers `/proc/environment/...` ou `/proc/brcm/blxparms/...`), hndmfg.sh
  a besoin d'envrams pour `envram get et0macaddr` avant que le nvram ASUS ne
  soit peuplé → on préserve le flow usine vendor.
- **Garde anti-doublon `pidof envrams.real`** : `pids("envrams")` côté
  rc/web_hook ne matche plus le nom de process (`envrams.real`), donc les
  appelants retenteraient le spawn ; le wrapper coupe court (exit 0 si déjà
  actif). Quand le gate est fermé, chaque tentative = exec sh + exit 0,
  négligeable.

### Interaction avec 0026 (conservé)

0026 est **inerte aujourd'hui** (ate.c jamais compilé, voir RE trail #3) ;
il est conservé car il redeviendrait la bonne défense si un futur merge
vendor supprime le prebuilt `ate.o` et recompile `ate.c`. Coût : nul.

### Effets de bord acceptés (documentés)

- `killall envrams` (hndmfg.sh `dlnvram`, `stop_envrams()` prebuilt) ne tue
  plus le daemon (nom de process `envrams.real`) — chemins mfg/ATE
  uniquement, inopérants quand le daemon est gaté (il ne tourne pas).
- ATE (`chk_envrams_proc` → `pids("envrams")`) répond `ATE_ERROR_NOT_ALLOWED`
  tant que `envrams_enable≠1` : voulu (commandes usine).
- Le code asusctrl du boot (init_asusctrl) ne pourra plus lire les variables
  envram quand le gate est fermé — même situation que sur l'objectif visé
  (envrams ne doit pas tourner) ; `envram get` côté client échoue proprement.

## Ré-activation

```
nvram set envrams_enable=1
nvram commit
# puis n'importe quel accès webui à une variable envram (httpd relance
# envrams de lui-même), ou au prochain boot via init_asusctrl
```

Retour à l'état gaté : `nvram unset envrams_enable; nvram commit` puis
`kill $(pidof envrams.real)` (ou reboot).

## Validation (build, sans flash)

- `./build.sh` exit 0 (2026-06-05), patches 0001-0032 appliqués ; 0032
  s'applique aussi sur le HEAD vendor pristine (`patch -p1 -N -F 10`,
  offset -20 lignes).
- `targets/96813GW/fs.install/usr/sbin/envrams` = wrapper sh 473 octets avec
  le gate (grep `envrams_enable` OK) ; `envrams.real` = daemon ELF ARM
  79640 octets ; idem dans `targets/96813GW/fs/` (source du squashfs).
- `strings fs.install/sbin/rc` : toujours `"/usr/sbin/envrams >/dev/null"`
  (prebuilt, attendu) → neutralisé par le wrapper.
- Artefacts snapshotés dans `gt-be98-firmware/artifacts-0032/` (2 pkgtb +
  `fs.install/sbin/rc` + wrapper) avec `SHA256SUMS` :
  - `GT-BE98_3006_102.6_0_nand_squashfs.pkgtb`
    `b3467b88bec667fd57991216d8a5dde2ac99c9d3a80fb88deb3cd8d12ef4dc66`
  - `GT-BE98_3006_102.6_0_nand_squashfs_loader.pkgtb`
    `f6f044bcdb0615352b47eb020a20c74d97ccc41433f313785855406b2e0571a6`

---

## ⚠️ ADDENDUM — hardware evidence against flashing 0032 as-is (2026-06-06, M4 bisect)

The br-0033 trial (2026-06-06 01:07) carried **exactly this wrapper+rename**
(`m4-staging/envrams-wrapper` is a verbatim mirror of the 0032 design,
applied to the 0031 rootfs via the Buildroot transform) alongside 22 file
removals. The trial boot was slow/network-broken AND **committed the
Broadcom BSP default base MAC (20:cf:30:00:00:00) into nvram**
(et0macaddr/label_mac/lan_hwaddr), surviving rollback and breaking the
DHCP reservation.

The M4 bisect (br-0035..br-0040, six trials, each gate 20/20) has now
cleared **every other ingredient** of that batch, individually and
cumulatively: br-0040 ≡ br-0033 minus only the wrapper, and it boots clean
with factory MACs intact. **By elimination, the gated-off wrapper caused
both symptoms on a NORMAL (non-mfg) boot.**

Consequence for this plan: the side effect accepted in "Effets de bord
acceptés" ("le code asusctrl ... ne pourra plus lire les variables envram
... échoue proprement") is **not benign on this board**: when
`init_asusctrl`'s envram read fails, the MAC-derivation path falls back to
the BSP default and **persists it via nvram commit** — observed on
hardware, not theoretical. Note nvram already held the factory
et0macaddr before br-0033 and was still overwritten: pre-seeding nvram
does NOT protect.

Recommendation: do NOT flash the artifacts-0032 pkgtb until the gate
design also covers the boot-time MAC path. Options to evaluate:
1. Wrapper allows envrams during early boot (e.g. uptime < 120 s or
   until a marker file), gates afterwards — preserves init_asusctrl's
   envram reads, still blocks steady-state/webui-triggered respawns.
2. Keep the current adopted stance (daemon runs; kill+firewall TCP 5152
   post-boot) — zero boot risk, envrams exposed only during boot.
3. Find/neutralize the BSP-fallback writer (asus_ctrl_envram_write /
   deconfig_nvram_envram in ate-broadcom.o) — prebuilt, likely
   un-patchable in text, same constraint as the start sites.
Any retest of a gated envrams MUST go through the v2 trial harness
(breadcrumbs + /data dead-man) with an nvram MAC backup staged, and check
`nvram get et0macaddr` + br0 MAC in the slice gate BEFORE adopting.
