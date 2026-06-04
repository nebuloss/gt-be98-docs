# Plan — Client list improvement: device icons + model (UniFi style)

## Context

Currently connected clients only display the MAC address + vendor name (text).
The user wants a UniFi-style presentation: an icon representing the device type
(phone, computer, TV, IoT, etc.) along with the manufacturer name — all in the frontend,
with no external dependencies (the router does not have reliable internet access).

## What already exists

- `src/www/oui.js`: OUI → vendor name table (text), ~400 prefixes, ~30 manufacturers
- `renderClients()` in `app.js`: displays the vendor below the MAC via `.client-vendor`
- "Device" column: green dot + MAC (monospace) + vendor (10px muted)

## What is missing

1. **Categorization by device type**: the same brand can be phone/tablet/TV/router.
   Apple → iPhone/iPad/MacBook/AppleTV depending on the MAC prefix.
2. **Inline SVG icons**: phone, laptop, desktop, tablet, tv, router, iot, printer, game, unknown.
3. **Enriched OUI**: associate each prefix with `{vendor, type}` instead of a simple string.

## Implementation plan

### 1. `src/www/oui.js` — Enrich the table

Replace the `'prefix': 'Vendor'` format with `'prefix': ['Vendor', 'type']`.
Available types: `phone`, `laptop`, `desktop`, `tablet`, `tv`, `router`, `iot`, `printer`, `game`, `ap`, `nas`.

Examples:
```js
// Apple
'3c22fb': ['Apple', 'phone'],    // iPhone
'a4d18c': ['Apple', 'laptop'],   // MacBook
'bc9fef': ['Apple', 'tv'],       // Apple TV
// Samsung
'8c77b3': ['Samsung', 'phone'],
'f4a7b3': ['Samsung', 'tv'],
// Raspberry Pi → iot/nas
'bc2411': ['Raspberry Pi', 'iot'],
// Espressif → iot
'2cf432': ['Espressif', 'iot'],
// Synology → nas
'001132': ['Synology', 'nas'],
// Nintendo → game
'002659': ['Nintendo', 'game'],
```

New functions:
```js
function ouiVendor(mac) { ... }   // string, comme avant (compatibilité)
function ouiType(mac) { ... }     // string: 'phone'|'laptop'|... ou 'unknown'
function ouiInfo(mac) { ... }     // {vendor, type}
```

### 2. `src/www/app.js` — SVG icons + enriched rendering

**Add a `DEVICE_ICONS` object** with an SVG path for each type:
```js
const DEVICE_ICONS = {
  phone:   '<svg ...>...</svg>',
  laptop:  '<svg ...>...</svg>',
  desktop: '<svg ...>...</svg>',
  tablet:  '<svg ...>...</svg>',
  tv:      '<svg ...>...</svg>',
  router:  '<svg ...>...</svg>',
  iot:     '<svg ...>...</svg>',
  printer: '<svg ...>...</svg>',
  game:    '<svg ...>...</svg>',
  ap:      '<svg ...>...</svg>',
  nas:     '<svg ...>...</svg>',
  unknown: '<svg ...>...</svg>',
};
function deviceIcon(mac) { return DEVICE_ICONS[ouiType(mac)] || DEVICE_ICONS.unknown; }
```

**Modify the "Device" cell** in `renderClients()`:
```
Before: [● dot]  [MAC]
                 [vendor text]

After:  [📱 icon]  [Vendor name]    ← vendor as primary if known
                   [MAC]            ← MAC as secondary (small monospace)
```

Wider column (from 180px → 200px) to accommodate the icon.

**Maintain compatibility**: if the vendor is unknown, display the `unknown` icon + MAC.

### 3. `src/www/style.css` — Icon styles

```css
.client-icon { width: 28px; height: 28px; flex-shrink: 0; color: var(--text2); }
.client-icon svg { width: 100%; height: 100%; }
.client-device-name { font-size: 12px; font-weight: 500; color: var(--text); }
.client-device-mac { font-family: monospace; font-size: 10px; color: var(--muted); }
```

Grid update:
```css
.client-row { grid-template-columns: 200px 100px 120px 60px 116px 100px 1fr 70px; }
```

## Modified files

| File | Change |
|---|---|
| `src/www/oui.js` | Enrich table: `'prefix': ['Vendor', 'type']` + functions `ouiType()`, `ouiInfo()` |
| `src/www/app.js` | Add `DEVICE_ICONS`, modify Device cell in `renderClients()` |
| `src/www/style.css` | Styles `.client-icon`, `.client-device-name`, `.client-device-mac`, adjust grid |

## Chosen icons (simple SVG 24×24, stroke-based, UniFi style)

- **phone**: rounded rectangle outline + bottom circle (phone screen)
- **laptop**: open trapezoid (screen) + flat rectangle (keyboard)
- **desktop**: monitor + base + stand
- **tablet**: rounded rectangle + circle (home button)
- **tv**: wide monitor + stand
- **router**: box with antennas
- **iot**: chip/circuit (square with pins)
- **printer**: box with slot + paper
- **game**: controller (simplified D-pad)
- **ap**: concentric half-circles (WiFi signal)
- **nas**: rack server
- **unknown**: question mark or generic device

## Verification

1. `bash deploy/push.sh admin@10.0.0.8 2222`
2. Open the UI → Connected clients section
3. Verify: phone icon for iPhone/Android, laptop for MacBook/PC, iot for Espressif/RPi
4. Unknown MACs display the `unknown` icon + raw MAC
5. Verify that known vendor names are displayed first (before the MAC)
