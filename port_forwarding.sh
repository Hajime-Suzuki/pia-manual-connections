#!/usr/bin/env bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This function allows you to check if the required tools have been installed.
check_tool() {
  cmd=$1
  if ! command -v "$cmd" >/dev/null; then
    echo "$cmd could not be found"
    echo "Please install $cmd"
    exit 1
  fi
}

# Now we call the function to make sure we can use curl and jq.
check_tool curl
check_tool jq

# Check if the mandatory environment variables are set.
if [[ -z $PF_GATEWAY || -z $PIA_TOKEN || -z $PF_HOSTNAME ]]; then
  echo "This script requires 3 env vars:"
  echo "PF_GATEWAY  - the IP of your gateway"
  echo "PF_HOSTNAME - name of the host used for SSL/TLS certificate verification"
  echo "PIA_TOKEN   - the token you use to connect to the vpn services"
  echo
  echo "An easy solution is to just run get_region_and_token.sh"
  echo "as it will guide you through getting the best server and"
  echo "also a token. Detailed information can be found here:"
  echo "https://github.com/pia-foss/manual-connections"
echo -e "\nOptional:\n  PF_TARGET_IP - LAN IP to DNAT the forwarded port to (e.g., 192.168.2.55)\n  PF_TARGET_PORT - target port for DNAT (default: same as PIA forwarded port)\n"
exit 1
fi

# Check if terminal allows output, if yes, define colors for output
if [[ -t 1 ]]; then
  ncolors=$(tput colors)
  if [[ -n $ncolors && $ncolors -ge 8 ]]; then
    red=$(tput setaf 1) # ANSI red
    green=$(tput setaf 2) # ANSI green
    nc=$(tput sgr0) # No Color
  else
    red=''
    green=''
    nc='' # No Color
  fi
fi

# The port forwarding system has required two variables:
# PAYLOAD: contains the token, the port and the expiration date
# SIGNATURE: certifies the payload originates from the PIA network.

# Basically PAYLOAD+SIGNATURE=PORT. You can use the same PORT on all servers.
# The system has been designed to be completely decentralized, so that your
# privacy is protected even if you want to host services on your systems.

# You can get your PAYLOAD+SIGNATURE with a simple curl request to any VPN
# gateway, no matter what protocol you are using. Considering WireGuard has
# already been automated in this repo, here is a command to help you get
# your gateway if you have an active OpenVPN connection:
# $ ip route | head -1 | grep tun | awk '{ print $3 }'
# This section will get updated as soon as we created the OpenVPN script.

# Get the payload and the signature from the PF API. This will grant you
# access to a random port, which you can activate on any server you connect to.
# If you already have a signature, and you would like to re-use that port,
# save the payload_and_signature received from your previous request
# in the env var PAYLOAD_AND_SIGNATURE, and that will be used instead.
if [[ -z $PAYLOAD_AND_SIGNATURE ]]; then
  echo
  echo -n "Getting new signature... "
  payload_and_signature="$(curl -s -m 5 \
    --connect-to "$PF_HOSTNAME::$PF_GATEWAY:" \
    --cacert "ca.rsa.4096.crt" \
    -G --data-urlencode "token=${PIA_TOKEN}" \
    "https://${PF_HOSTNAME}:19999/getSignature")"
else
  payload_and_signature=$PAYLOAD_AND_SIGNATURE
  echo -n "Checking the payload_and_signature from the env var... "
fi
export payload_and_signature

# Check if the payload and the signature are OK.
# If they are not OK, just stop the script.
if [[ $(echo "$payload_and_signature" | jq -r '.status') != "OK" ]]; then
  echo -e "${red}The payload_and_signature variable does not contain an OK status.${nc}"
  exit 1
fi
echo -e "${green}OK!${nc}"

# We need to get the signature out of the previous response.
# The signature will allow the us to bind the port on the server.
signature=$(echo "$payload_and_signature" | jq -r '.signature')

# The payload has a base64 format. We need to extract it from the
# previous response and also get the following information out:
# - port: This is the port you got access to
# - expires_at: this is the date+time when the port expires
payload=$(echo "$payload_and_signature" | jq -r '.payload')
port=$(echo "$payload" | base64 -d | jq -r '.port')

# The port normally expires after 2 months. If you consider
# 2 months is not enough for your setup, please open a ticket.
expires_at=$(echo "$payload" | base64 -d | jq -r '.expires_at')

# DNAT cleanup function: removes all DNAT and accept rules for PF_TARGET_IP
remove_dnat() {
    if [[ -z ${PF_TARGET_IP:-} ]]; then
        return
    fi

    nft -a list chain ip nat PREROUTING 2>/dev/null | \
      grep "dnat to $PF_TARGET_IP:" | \
      sed 's/.*handle //' | \
      while read -r handle; do
        nft delete rule ip nat PREROUTING handle "$handle" 2>/dev/null || true
      done

    nft -a list chain inet pia_killswitch forward 2>/dev/null | \
      grep "ip daddr $PF_TARGET_IP accept" | \
      sed 's/.*handle //' | \
      while read -r handle; do
        nft delete rule inet pia_killswitch forward handle "$handle" 2>/dev/null || true
      done

    nft -a list chain inet pia_killswitch output 2>/dev/null | \
      grep "ip daddr $PF_TARGET_IP accept" | \
      sed 's/.*handle //' | \
      while read -r handle; do
        nft delete rule inet pia_killswitch output handle "$handle" 2>/dev/null || true
      done

    nft -a list chain inet pia_killswitch input 2>/dev/null | \
      grep "tcp dport $PF_TARGET_PORT accept" | \
      sed 's/.*handle //' | \
      while read -r handle; do
        nft delete rule inet pia_killswitch input handle "$handle" 2>/dev/null || true
      done
}
trap remove_dnat EXIT

echo -ne "
Signature ${green}$signature${nc}
Payload   ${green}$payload${nc}

--> The port is ${green}$port${nc} and it will expire on ${red}$expires_at${nc}. <--

Trying to bind the port... "

# Now we have all required data to create a request to bind the port.
# We will repeat this request every 15 minutes, in order to keep the port
# alive. The servers have no mechanism to track your activity, so they
# will just delete the port forwarding if you don't send keepalives.
while true; do
  bind_port_response="$(curl -Gs -m 5 \
    --connect-to "$PF_HOSTNAME::$PF_GATEWAY:" \
    --cacert "ca.rsa.4096.crt" \
    --data-urlencode "payload=${payload}" \
    --data-urlencode "signature=${signature}" \
    "https://${PF_HOSTNAME}:19999/bindPort")"
    echo -e "${green}OK!${nc}"

    # If port did not bind, just exit the script.
    # This script will exit in 2 months, since the port will expire.
    export bind_port_response
    if [[ $(echo "$bind_port_response" | jq -r '.status') != "OK" ]]; then
      echo -e "${red}The API did not return OK when trying to bind port... Exiting.${nc}"
      exit 1
    fi
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    echo -e Forwarded port'\t'"${green}$port${nc}"
    echo -e Refreshed on'\t'"${green}$(date)${nc}"
    echo -e Expires on'\t'"${red}$(date --date="$expires_at")${nc}"

    # Port is bound. Re-enable killswitch so traffic is locked to the VPN tunnel.
    # Subsequent keepalive curls go through the pia interface and are allowed.
    echo "Re-enabling kill switch..."
    nft delete table inet pia_killswitch 2>/dev/null || true
    nft -f /etc/nftables-pia.conf

    # DNAT: forward incoming traffic on the PIA port to the target LAN IP
    if [[ -n ${PF_TARGET_IP:-} ]]; then
      target_port="${PF_TARGET_PORT:-$port}"
      # Ensure ip nat table and PREROUTING chain exist (created once, harmless on repeat)
      nft add table ip nat 2>/dev/null || true
      nft add chain ip nat PREROUTING '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
      # Remove old rules for this target (port may have changed on re-bind)
      remove_dnat
      echo "Adding DNAT rule: pia:$port → $PF_TARGET_IP:$target_port"
      nft insert rule ip nat PREROUTING iifname pia tcp dport "$port" dnat to "$PF_TARGET_IP":"$target_port"
      echo "Adding forward accept rule for $PF_TARGET_IP:$target_port"
      nft insert rule inet pia_killswitch forward tcp dport "$target_port" ip daddr "$PF_TARGET_IP" accept
      echo "Allowing outbound traffic to $PF_TARGET_IP"
      nft insert rule inet pia_killswitch output ip daddr "$PF_TARGET_IP" accept
      echo "Allowing inbound traffic on forwarded port in killswitch INPUT chain"
      nft insert rule inet pia_killswitch input tcp dport "$target_port" accept
    fi

    echo -e "\n${green}This script will need to remain active to use port forwarding, and will refresh every 15 minutes.${nc}\n"

    # sleep 15 minutes
    sleep 900
done
