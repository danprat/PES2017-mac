# Pillar 4: Offline Bot Warfare & Secured Netcode

## Overview
Retail *Call of Duty: Modern Warfare 2 (2009)* on Xbox 360 does not feature offline multiplayer bot matches out of the box (multiplayer required either Xbox Live or an active system link session with other physical consoles). Additionally, legacy 2009 netcode has known security vulnerabilities when exposed to untrusted networks.

By referencing [`shit-ware/iw4x-rawfiles`](https://github.com/shit-ware/iw4x-rawfiles) and [`shit-ware/iw4x-client`](https://github.com/shit-ware/iw4x-client), we can bring complete offline bot warfare and hardened local/online networking to the Android port.

---

## Technical Solutions

### 1. Offline Bot Warfare Injection (Bot AI via GSC)
- **Source**: Bot Warfare GSC scripts from `iw4x-rawfiles/scripts/bots/`.
- **How it works**:
  - The scripts define waypoint navigation graphs, line-of-sight target acquisition, weapon recoil compensation, and customizable bot difficulties (Recruit, Regular, Hardened, Veteran).
  - Scripts are loaded through our virtual filesystem (`runtime/vfs/`) into the game's internal script VM during map initialization (`InitGSC()`).
  - Enables full 6v6 or 9v9 Team Deathmatch, Free-for-All, Domination, and Search & Destroy offline on Android anytime, anywhere without an internet connection.

### 2. Netcode Hardening & Security Patches
From `iw4x-client/src/client/network/`:
- **String Tokenization Overflow**: Enforce strict length bounds on `Cmd_TokenizeString` to prevent buffer overflows from oversized chat strings or player nicknames.
- **Connectionless Packet Filtering**: Validate header size and drop malformed packets in `CL_ConnectionlessPacket` and `SV_ExecuteClientMessage`.
- **Voice Packet Bounds**: Restrict voice packet payloads to valid Speex/Silk frame sizes to eliminate remote heap corruptions.

### 3. Touchscreen Controls & Gyroscope Look Aiming
- Customizable on-screen HUD with virtual joysticks, ADS toggle, and velocity-based aim drag.
- Gyroscope sensor fusion via Android `ASensorManager` mapped directly to guest camera yaw and pitch deltas for console-grade aiming accuracy on mobile.
