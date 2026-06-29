# Kill Switch Two-Switch Implementation Plan

## Problem
When reconnecting PIA VPN with an active killswitch (`/etc/nftables-pia.conf`), all outbound traffic is blocked — including the curl calls that `get_token.sh`, `get_region.sh`, and `connect_to_wireguard_with_token.sh` need to reach PIA APIs. The current code uses `nft flush ruleset` which runs too late (inside the connect script after curls already fail).

## Solution
Each sub-script temporarily deletes the killswitch nftables table before its curl call, then re-applies it immediately after. This opens a window of one HTTP request per script.

## Killswitch Config (`/etc/nftables-pia.conf`)
Rewrite to use named table `inet pia_killswitch` (no `flush ruleset` at top):

```
#!/usr/sbin/nft -f

table inet pia_killswitch {
    chain output {
        type filter hook output priority 0; policy drop;
        oif "lo" accept
        ct state established,related accept
        oifname "pia*" accept
    }
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport 22 accept
        tcp dport 5173 accept
    }
}
```

## Changes by file

### 1. `/etc/nftables-pia.conf`
- Replace content with the ruleset above
- Remove the top-level `flush ruleset` command
- Change table name from `inet filter` to `inet pia_killswitch`

### 2. `get_token.sh`
- **Before line 72** (the `for` loop that curls for connectivity check): add `nft delete table inet pia_killswitch 2>/dev/null || true`
- **After line 85** (after the POST curl succeeds, line 83): add re-apply of killswitch: `[[ -f /etc/nftables-pia.conf ]] && nft -f /etc/nftables-pia.conf`
- **Before any `exit`** (lines 80, 92): add `[[ -f /etc/nftables-pia.conf ]] && nft -f /etc/nftables-pia.conf`

### 3. `get_region.sh`
- **Before line 133** (`all_region_data=$(curl ...)`): add `nft delete table inet pia_killswitch 2>/dev/null || true`
- **After line 133** (right after curl succeeds): add `[[ -f /etc/nftables-pia.conf ]] && nft -f /etc/nftables-pia.conf`
- **Before any `exit 1`**: add same re-apply

### 4. `connect_to_wireguard_with_token.sh`
- **Before line 104** (the addKey curl): add `nft delete table inet pia_killswitch 2>/dev/null || true`
- **Lines 136-138**: keep `nft flush ruleset` as safety net (or replace with targeted delete — either is fine, flush is more aggressive but covers edge cases)
- **After line 195** (after `wg-quick up`): keep existing killswitch re-apply at lines 200-203
- **Before any `exit 1` after line 104**: add re-apply of killswitch

## Execution flow
```
get_token.sh:
  delete pia_killswitch table
  curl API
  re-apply killswitch config
  exit

get_region.sh:
  delete pia_killswitch table  
  curl serverlist
  re-apply killswitch config
  exit

connect_to_wireguard_with_token.sh:
  wg-quick down (existing)
  flush ruleset (existing safety net)
  delete pia_killswitch table
  curl addKey
  wg-quick up
  re-apply killswitch config (tunnel active)
  exit
```

## Error handling
- `get_token.sh` / `get_region.sh`: re-apply killswitch on any failure path
- `connect_to_wireguard_with_token.sh`: re-apply killswitch on any failure path after the addKey curl; a `trap EXIT` can guarantee this

## Validation
1. Killswitch active → run `get_token.sh` → succeeds, killswitch re-applied after
2. Killswitch active → run `get_region.sh` → succeeds, killswitch re-applied after
3. Full `run_setup.sh` flow → VPN connects, killswitch active post-connection
4. `nft list ruleset` shows `table inet pia_killswitch` after VPN is up
5. Disconnect → `nft list ruleset` shows no `pia_killswitch` table
