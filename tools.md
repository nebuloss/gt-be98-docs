# System tools available on the GT-BE98

> 📌 For the **live-verified** behavior (interface model, SDN/apg,
> fast apply commands without `restart_wireless`), see
> [behaviour.md](behaviour.md).

## nvram management

```sh
nvram get <key>             read a value
nvram set <key>=<value>     write (in memory)
nvram unset <key>           delete
nvram commit                persist to flash
nvram show                  full dump (~8000 entries)
```

## Wi-Fi management

```sh
wlconf <ifname> up          apply nvram config on the interface
wlconf <ifname> down        disable
wlconf <ifname> start       start BSS
wlconf <ifname> security    apply security config
wlconf <ifname> forceup     force activation

wl -i wlX band              active band (a=5G, b=2.4G)
wl -i wlX chanlist          list of available channels
wl -i wlX channel           current channel
wl -i wlX ssid              current SSID
wl -i wlX status            radio status
wl -i wlX assoclist         list of connected clients
wl -i wlX bss               BSS status (up/down)
wl -i wlX.N bss             virtual BSS status
```

## Restarting services

```sh
service restart_wireless        restart all Wi-Fi BSS (~5s outage)
service restart_net             restart the full network stack
service restart_firewall        reload the iptables rules
service restart_dnsmasq         restart DHCP/DNS
service restart_httpd           restart the Asus web server
```

## Network / VLAN

```sh
# Create VLAN interface
ip link add link eth0 name eth0.40 type vlan id 40

# Create bridge
ip link add name br40 type bridge
ip link set br40 up
ip addr add 192.168.4.1/24 dev br40

# Add interface to the bridge
ip link set eth0.40 master br40
ip link set wl0.40 master br40

# Old style
vconfig add eth0 40
brctl addbr br40
brctl addif br40 eth0.40

# VLAN switch BCM6813
vlanctl                     VLAN management at switch level
ethswctl                    ethernet switch configuration
```

## Web server

```sh
lighttpd -v                 → lighttpd/1.4.39 (ssl) — already present !
lighttpd -f /path/conf      start with a custom config
```

**lighttpd is already embedded in the firmware.**
You just need to add a config in `/jffs/` and launch it on another port.

Current processes:
- `httpd` → port 80 (Asus HTTP)
- `httpds` → port 8443 (Asus HTTPS)
- Available port: **8080** (or another)

## Other

```sh
brctl show                  list of bridges and their members
brctl showmacs br0          MAC table of a bridge
ip link show                all interfaces
ip addr show                IP addresses
iptables -L -n -v           firewall rules
cat /proc/net/arp           ARP table (connected clients)
```

## Relevant config files

```
/tmp/etc/dnsmasq.conf       active DHCP/DNS config (tmpfs)
/tmp/etc/lighttpd.conf      active lighttpd config (tmpfs)
/jffs/scripts/              persistent scripts (post-mount, services)
/jffs/configs/              persistent configs
/etc/init.d/                init scripts (read-only)
```
