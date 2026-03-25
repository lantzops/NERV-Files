# NERV Home Automation — Starter Shopping List

## Zigbee Coordinator

| Item | Price (est.) | Notes |
|------|-------------|-------|
| SONOFF Zigbee 3.0 USB Dongle Plus-E (ZBDongle-E) | ~$13 | EFR32MG21 chip, pre-flashed coordinator firmware. Use with a USB extension cable — USB 3.0 ports cause 2.4GHz interference that degrades Zigbee. Passes through to HA VM via Proxmox USB passthrough. |

---

## Smart Switches — Inovelli Blue Series (Zigbee 3.0)

| Item | Qty | Price Each (est.) | Notes |
|------|-----|-------------------|-------|
| Inovelli Blue Series 2-1 Dimmer (VZM31-SN) | 6 | ~$60 | Dimmer + on/off in one unit. LED notification bar, multi-tap scene control, 80+ configurable parameters. Works with Home Assistant via Zigbee2MQTT or ZHA. **Stock alert:** These have had intermittent stock issues — check inovelli.com and Amazon for current availability. |
| Lutron Claro Wallplates (1-gang) | 6 | ~$3–5 | Inovelli recommends Claro plates — their switch colors are matched to this line. Not included in the box. |

**Important notes on the Inovelli Blues:**

- They require a **neutral wire** for the most reliable operation. Most homes built after ~1985 have neutrals in the switch box, but verify before ordering. Non-neutral installs are possible but need a bypass module (~$10) and have some limitations.
- If any switches control a **3-way circuit** (two switches for one light), you'll either use your existing dumb switch on the other end OR buy Inovelli Aux switches (~$15 each). Dumb switches work but dimming is only available from the Inovelli side.
- These switches are **not rated for LED strips, transformers, or fans**. Use them for standard lighting loads only. For LED strips, see the section below.
- Each switch acts as a **Zigbee router/repeater**, strengthening your mesh network. Six of these scattered around the house gives you excellent coverage.

---

## Motion Sensors

| Item | Qty | Price Each (est.) | Notes |
|------|-----|-------------------|-------|
| Aqara Motion Sensor P1 (Zigbee) | 3–4 | ~$18–22 | Zigbee 3.0, 170° detection angle, 7m range, 5-year battery (CR2450). Configurable detection timeout (1–200s). Well-supported in Zigbee2MQTT. Great for hallways, bathrooms, stairways. |

**Why the P1 over the P2:** The P2 is Matter/Thread — great protocol, but since your whole stack is Zigbee (coordinator, switches, LED controllers), keeping sensors on the same protocol simplifies everything. The P1 is also cheaper and has identical detection performance. If you later want to go Thread, the SONOFF dongle can be reflashed to support it.

**Placement tips:**

- Mount at ~7ft height angled slightly downward for best hallway coverage
- Use the included 360° adjustable stand — adhesive mount works fine, no screws needed
- Keep sensors away from heat sources (HVAC vents, radiators) to avoid false triggers
- For the nighttime pathway automation, you want sensors at transition points: hallway entrance, bathroom doorway, stairway landing

---

## LED Strip Lighting (3 Options for Different Use Cases)

Since Inovelli dimmers **cannot** drive LED strips directly, you need a separate Zigbee controller + power supply + strip for each zone.

### Option 1: Under-Cabinet Kitchen Lighting

| Item | Qty | Price (est.) | Notes |
|------|-----|-------------|-------|
| Gledopto GL-C-002P Zigbee Mini LED Controller | 1 | ~$16–20 | Ultra-thin Zigbee 3.0 RGBCCT controller. Fits behind cabinets easily. Supports warm white through cool white + RGB. |
| 12V Warm White LED Strip (2835 SMD, ~16ft) | 1 | ~$10–15 | For under-cabinet, warm white (2700K–3000K) looks best. Cut to length at marked intervals. |
| 12V 3A Power Supply | 1 | ~$8–12 | Matched to strip length and wattage. |

### Option 2: Hallway Pathway Lighting (Outlet-Powered)

| Item | Qty | Price (est.) | Notes |
|------|-----|-------------|-------|
| Gledopto GL-C-001P Zigbee 5-in-1 LED Controller | 1 | ~$20–25 | Full-size controller, supports single color through RGBCCT. Plug the power supply into a standard outlet. |
| 12V RGBW or Warm White LED Strip (~10–16ft) | 1 | ~$10–18 | RGBW gives you the option of dim warm amber at night, full white during the day. |
| 12V 5A Power Supply with barrel connector | 1 | ~$10–15 | Size appropriately for strip length. |

**Pro tip:** Run the strip along the baseboard or under a shelf at ankle height. At 2–5% brightness, warm amber provides enough light to navigate without blinding you at 2am.

### Option 3: Accent / Ambient Lighting (Bedroom, Entertainment Area)

| Item | Qty | Price (est.) | Notes |
|------|-----|-------------|-------|
| GIDERWEL Zigbee RGBW LED Strip Kit | 1 | ~$30–35 | All-in-one kit: Zigbee 3.0 controller + RGBW LED strip (32.8ft) + power supply. Less fiddling with separate components. Supported in Zigbee2MQTT. |

---

## Thermostat

| Item | Notes |
|------|-------|
| **Keep your existing Nest** | Integrates with Home Assistant via the Google Home / Nest integration. You get HA dashboard control, automation triggers (away mode, temperature thresholds), and phone control you already use. The Zigbee thermostat market for US forced-air HVAC is mediocre — nothing matches the Nest's hardware quality. Save the ~$100+ and put it toward more sensors or switches. |

---

## Extras Worth Considering

| Item | Price (est.) | Notes |
|------|-------------|-------|
| USB Extension Cable (6ft, USB-A) | ~$5 | For the Zigbee coordinator. Seriously, don't skip this — USB 3.0 interference is real. |
| Aqara Door/Window Sensor (Zigbee) | ~$12–15 each | Great for "turn off all lights when everyone leaves" automations, or alerts if a door is left open. |
| SONOFF Zigbee Smart Plug (S31 Lite ZB) | ~$10–12 each | Acts as a Zigbee router + gives you smart outlet control. Good for lamps that aren't on a wall switch. |

---

## Estimated Budget Summary

| Category | Est. Cost |
|----------|-----------|
| Zigbee Coordinator | ~$13 |
| 6x Inovelli Blue Dimmers | ~$360 |
| 6x Wallplates | ~$20–30 |
| 3–4x Motion Sensors | ~$55–90 |
| LED Strip Setup (3 zones) | ~$100–140 |
| USB Extension Cable | ~$5 |
| **Total (core kit)** | **~$550–640** |

Add-ons like door sensors, smart plugs, and bypass modules (if needed) would add another $50–100 depending on quantity.

---

## Software Stack (runs on NERV / Proxmox)

- **Home Assistant OS** — Proxmox VM (they publish a qcow2 image)
- **Zigbee2MQTT** — manages the coordinator and all Zigbee devices
- **Mosquitto** — MQTT broker bridging Zigbee2MQTT ↔ Home Assistant
- **Nest Integration** — built into Home Assistant, connects via Google cloud API

---

*Last updated: March 2026. Prices are approximate — check Amazon, inovelli.com, and the Aqara store for current availability.*
