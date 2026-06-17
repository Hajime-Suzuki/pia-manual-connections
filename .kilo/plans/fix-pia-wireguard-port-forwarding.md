# Fix PIA WireGuard Port Forwarding Bug

## Problem
`connect_to_wireguard_with_token.sh` passes `PF_GATEWAY=$WG_SERVER_IP` to `port_forwarding.sh`, but PIA's port forwarding API (port 19999) runs on the **meta server IP** (`.servers.meta[0].ip`), not the WireGuard endpoint IP (`.servers.wg[0].ip`).

## Evidence
Your Romania connection showed:
- WireGuard endpoint: `143.244.54.4:1337` (connected successfully)
- Script tried: `143.244.54.4:19999` for port forwarding (failed - timeout)
- PIA meta IP (correct): `143.244.54.5:19999`

## Current Flow
```
run_setup.sh → get_region.sh (line 243-244)
  - Exports: WG_SERVER_IP, WG_HOSTNAME
  - Missing: PF_GATEWAY, PF_HOSTNAME (meta IP for port forwarding)

connect_to_wireguard_with_token.sh (line 230-233)
  - Uses: PF_GATEWAY=$WG_SERVER_IP (WRONG - uses WG endpoint IP)
```

## Recommended Fix

### Change 1: `get_region.sh` lines 243-244 (AUTOCONNECT path)
Pass the meta IP/hostname from region data to WireGuard script.

**Before:**
```bash
PIA_PF=$PIA_PF PIA_TOKEN=$PIA_TOKEN WG_SERVER_IP=$bestServer_WG_IP \
  WG_HOSTNAME=$bestServer_WG_hostname ./connect_to_wireguard_with_token.sh
```

**After:**
```bash
PIA_PF=$PIA_PF PIA_TOKEN=$PIA_TOKEN WG_SERVER_IP=$bestServer_WG_IP \
  WG_HOSTNAME=$bestServer_WG_hostname \
  PF_GATEWAY=$bestServer_meta_IP PF_HOSTNAME=$bestServer_meta_hostname \
  ./connect_to_wireguard_with_token.sh
```

### Change 2: `connect_to_wireguard_with_token.sh` lines 230-233
Use passed variables with fallback to current behavior.

**Before:**
```bash
PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY=$WG_SERVER_IP \
  PF_HOSTNAME=$WG_HOSTNAME \
  ./port_forwarding.sh
```

**After:**
```bash
PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY=${PF_GATEWAY:-$WG_SERVER_IP} \
  PF_HOSTNAME=${PF_HOSTNAME:-$WG_HOSTNAME} \
  ./port_forwarding.sh
```

Note: This allows backward compatibility and manual override.

### Change 3: `run_setup.sh` (DIP_TOKEN + wireguard path - optional enhancement)
For dedicated IP path, the meta IP needs to be fetched from region API since `get_dip.sh` only provides WG endpoint. This can be a separate fix.

## Implementation Steps

1. Modify `get_region.sh` line 243-244 to pass `PF_GATEWAY` and `PF_HOSTNAME`
2. Modify `connect_to_wireguard_with_token.sh` line 230-233 to use passed variables
3. Test: `PIA_PF=true PIA_USER=xxx PIA_PASS=xxx VPN_PROTOCOL=wireguard ./run_setup.sh`

## Verification
After fix, `port_forwarding.sh` should:
- Connect to correct meta IP on port 19999
- Output "OK!" for signature request
- Output "Forwarded port XXXXX" with the assigned port
- Refresh every 15 minutes