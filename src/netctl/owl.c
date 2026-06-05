/*
 * owl — open-wl: a minimal, dependency-free reimplementation of the read/diagnostic
 * side of Broadcom's proprietary `wl` tool for the GT-BE98 (BCM6813, impl105 driver).
 *
 * It talks to the wl driver exactly the way the open shared/wl_linux.c does: a
 * SIOCDEVPRIVATE ioctl carrying a wl_ioctl_t {cmd,buf,len,set,...}. No wlioctl.h,
 * no libwlcsm — just the ABI. Built static for 32-bit ARM (router userspace).
 *
 * Verified live against stock `wl` on the AP. Commands (read-only, safe):
 *   owl <if> ssid            WLC_GET_SSID (25)      -> SSID string
 *   owl <if> bssid           WLC_GET_BSSID (23)     -> MAC
 *   owl <if> chanspec        iovar "chanspec"       -> 0xXXXX
 *   owl <if> bss_enabled     iovar "bss" (int)      -> 0/1 (BSS up state)
 *   owl <if> assoclist       WLC_GET_ASSOCLIST(159) -> associated client MACs
 *   owl <if> getvar <name>   WLC_GET_VAR (262)      -> raw hex (generic iovar probe)
 *
 * RE refs: shared/wl_linux.c (ioctl path), wlioctl.h (wl_ioctl_t, wlc_ssid_t),
 * wlioctl_defs.h (command numbers). See ../../netctl-verified.md / wl-interface.md.
 *
 * Scope: owl is the open read path for the small FIXED-layout iovars. A site survey
 * (WLC_SCAN/WLC_SCAN_RESULTS) is deliberately NOT here — its wl_bss_info_t is large and
 * version-stamped (offsets vary per driver build), so it lives in `netctl scan <radio>`,
 * which robustly parses the stock `wl scanresults` text instead.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>

#define WLC_GET_MAGIC       0
#define WLC_GET_BSSID       23
#define WLC_GET_SSID        25
#define WLC_GET_CHANNEL     29
#define WLC_GET_ASSOCLIST   159
#define WLC_GET_VAR         262
#define WLC_SET_VAR         263
#define WLC_IOCTL_MAGIC     0x14e46c77

/* wl_ioctl_t — must match the kernel driver ABI (wlioctl.h). On 32-bit ARM this is
 * 24 bytes: cmd(4) buf(4) len(4) set(1)+pad(3) used(4) needed(4). */
typedef struct wl_ioctl {
	uint32_t cmd;
	void    *buf;
	uint32_t len;
	uint8_t  set;
	uint32_t used;
	uint32_t needed;
} wl_ioctl_t;

#define DOT11_MAX_SSID_LEN 32
typedef struct wlc_ssid { uint32_t SSID_len; uint8_t SSID[DOT11_MAX_SSID_LEN]; } wlc_ssid_t;
struct ether_addr { uint8_t octet[6]; };
struct maclist { uint32_t count; struct ether_addr ea[1]; };

static int wl_ioctl(const char *name, int cmd, void *buf, int len, int set)
{
	struct ifreq ifr;
	wl_ioctl_t ioc;
	int s, ret;

	if ((s = socket(AF_INET, SOCK_DGRAM, 0)) < 0) { perror("socket"); return -errno; }
	memset(&ioc, 0, sizeof(ioc));
	ioc.cmd = cmd; ioc.buf = buf; ioc.len = len; ioc.set = set ? 1 : 0;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
	ifr.ifr_data = (caddr_t)&ioc;
	ret = ioctl(s, SIOCDEVPRIVATE, &ifr);
	close(s);
	return ret < 0 ? -errno : ret;
}

/* iovar get: the iovar name (NUL-terminated) goes at the head of buf; the driver
 * writes the result back over buf. */
static int wl_iovar_get(const char *ifname, const char *iovar, void *outbuf, int outlen)
{
	char buf[4096];
	int nlen = strlen(iovar) + 1;
	if (nlen > (int)sizeof(buf)) return -1;
	memset(buf, 0, sizeof(buf));
	strcpy(buf, iovar);
	int r = wl_ioctl(ifname, WLC_GET_VAR, buf, sizeof(buf), 0);
	if (r < 0) return r;
	memcpy(outbuf, buf, outlen);
	return 0;
}

static int wl_iovar_getint(const char *ifname, const char *iovar, int *val)
{
	return wl_iovar_get(ifname, iovar, val, sizeof(int));
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: owl <ifname> ssid|bssid|chanspec|bss_enabled|assoclist|getvar <name>\n");
		return 2;
	}
	const char *ifn = argv[1], *cmd = argv[2];

	if (!strcmp(cmd, "ssid")) {
		wlc_ssid_t s; memset(&s, 0, sizeof(s));
		if (wl_ioctl(ifn, WLC_GET_SSID, &s, sizeof(s), 0) < 0) { perror("WLC_GET_SSID"); return 1; }
		uint32_t n = s.SSID_len > DOT11_MAX_SSID_LEN ? DOT11_MAX_SSID_LEN : s.SSID_len;
		printf("%.*s\n", (int)n, s.SSID);
	} else if (!strcmp(cmd, "bssid")) {
		struct ether_addr e; memset(&e, 0, sizeof(e));
		if (wl_ioctl(ifn, WLC_GET_BSSID, &e, sizeof(e), 0) < 0) { perror("WLC_GET_BSSID"); return 1; }
		printf("%02X:%02X:%02X:%02X:%02X:%02X\n", e.octet[0],e.octet[1],e.octet[2],e.octet[3],e.octet[4],e.octet[5]);
	} else if (!strcmp(cmd, "bss_enabled")) {
		int v = 0; if (wl_iovar_getint(ifn, "bss", &v) < 0) { fprintf(stderr,"bss failed\n"); return 1; }
		printf("%d\n", v);
	} else if (!strcmp(cmd, "chanspec")) {
		int v = 0; if (wl_iovar_getint(ifn, "chanspec", &v) < 0) { fprintf(stderr,"chanspec failed\n"); return 1; }
		printf("0x%04x\n", v & 0xffff);
	} else if (!strcmp(cmd, "assoclist")) {
		char buf[4096]; memset(buf, 0, sizeof(buf));
		*(uint32_t *)buf = (sizeof(buf) - sizeof(uint32_t)) / sizeof(struct ether_addr);
		if (wl_ioctl(ifn, WLC_GET_ASSOCLIST, buf, sizeof(buf), 0) < 0) { perror("WLC_GET_ASSOCLIST"); return 1; }
		struct maclist *ml = (struct maclist *)buf;
		printf("assoclist %u\n", ml->count);
		for (uint32_t i = 0; i < ml->count; i++) {
			uint8_t *o = ml->ea[i].octet;
			printf("%02X:%02X:%02X:%02X:%02X:%02X\n", o[0],o[1],o[2],o[3],o[4],o[5]);
		}
	} else if (!strcmp(cmd, "getvar") && argc >= 4) {
		char buf[4096]; if (wl_iovar_get(ifn, argv[3], buf, sizeof(buf)) < 0) { fprintf(stderr,"getvar %s failed\n", argv[3]); return 1; }
		printf("int=%d hex=0x%08x  bytes:", *(int *)buf, *(uint32_t *)buf);
		for (int i = 0; i < 16; i++) printf(" %02x", (uint8_t)buf[i]);
		printf("\n");
	} else {
		fprintf(stderr, "unknown command: %s\n", cmd); return 2;
	}
	return 0;
}
