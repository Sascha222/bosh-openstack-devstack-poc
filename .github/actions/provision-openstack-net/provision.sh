#!/usr/bin/env bash
# Provision test network topology on DevStack using the openstack CLI,
# replacing the upstream terraform modules. Emits metadata.json with the exact
# keys the consuming scripts read via jq.
#
# TOPOLOGY=lifecycle -> mirrors terraform modules/{base,lifecycle}
#                       (consumed by ci/tasks/run-lifecycle.sh)
# TOPOLOGY=bats      -> mirrors terraform modules/{base,bats} + bats-manual root
#                       (consumed by deploy-manual-networking.sh + run-manual-networking-bats.sh)
set -euo pipefail

TOPOLOGY="${TOPOLOGY:-lifecycle}"
PREFIX="${PREFIX:-$TOPOLOGY}"
EXT_NET="${EXT_NET:-public}"
DNS_NS="${DNS_NS:-8.8.8.8}"
PUBKEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"
OUT="${OUT:-metadata.json}"
mkdir -p "$(dirname "$OUT")"

PROJECT="${OS_PROJECT_NAME:-admin}"
KEY_NAME="${PREFIX}-${PROJECT}"

id_of() { openstack "$1" show "$2" -f value -c id; }
port_ip() { openstack port show "$1" -f json | jq -r '.fixed_ips[0].ip_address // empty' ; }

# --- shared base: keypair, security group, router ---------------------------
echo "=== keypair ${KEY_NAME} ==="
if [ ! -f "$PUBKEY_FILE" ]; then
  ssh-keygen -t rsa -b 2048 -N "" -f "${PUBKEY_FILE%.pub}"
fi
openstack keypair create --public-key "$PUBKEY_FILE" "$KEY_NAME" >/dev/null 2>&1 || \
  echo "keypair ${KEY_NAME} already exists"

echo "=== security group ${PREFIX} ==="
openstack security group create "$PREFIX" --description "cpi ${TOPOLOGY} tests" >/dev/null 2>&1 || true
SG_ID=$(id_of "security group" "$PREFIX")
SG_NAME="$PREFIX"

add_rule() { openstack security group rule create "$@" "$SG_ID" >/dev/null 2>&1 || true; }
add_rule --protocol tcp  --remote-group "$SG_ID"
add_rule --protocol udp  --remote-group "$SG_ID"
add_rule --protocol icmp --remote-group "$SG_ID"
add_rule --protocol tcp  --dst-port 22:22       --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 25555:25555 --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 6868:6868   --remote-ip 0.0.0.0/0
add_rule --protocol udp  --dst-port 53:53       --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 53:53       --remote-ip 0.0.0.0/0

echo "=== router ${PREFIX}-router (ext gw ${EXT_NET}) ==="
openstack router create "${PREFIX}-router" >/dev/null 2>&1 || true
openstack router set --external-gateway "$EXT_NET" "${PREFIX}-router" >/dev/null 2>&1 || true

make_net() {
  local name=$1 cidr=$2 gw=$3 dhcp=$4 attach=$5
  openstack network create "$name" >/dev/null 2>&1 || true
  local dhcp_flag="--dhcp"; [ "$dhcp" = "no" ] && dhcp_flag="--no-dhcp"
  openstack subnet create "${name}-sub" \
    --network "$name" --subnet-range "$cidr" --gateway "$gw" \
    --dns-nameserver "$DNS_NS" $dhcp_flag >/dev/null 2>&1 || true
  if [ "$attach" = "yes" ]; then
    openstack router add subnet "${PREFIX}-router" "${name}-sub" >/dev/null 2>&1 || true
  fi
  id_of network "$name"
}

if [ "$TOPOLOGY" = "lifecycle" ]; then
  # --- lifecycle topology (modules/lifecycle) -------------------------------
  echo "=== networks (lifecycle) ==="
  NET_ID=$(make_net     "${PREFIX}"            "10.0.1.0/24" "10.0.1.1" yes yes)
  NET_ID_ND1=$(make_net "${PREFIX}-no-dhcp-1"  "10.1.1.0/24" "10.1.1.1" no  no)
  NET_ID_ND2=$(make_net "${PREFIX}-no-dhcp-2"  "10.2.1.0/24" "10.2.1.1" no  no)

  echo "=== allowed-address-pairs port ==="
  openstack port create --network "${PREFIX}" "${PREFIX}-aap" >/dev/null 2>&1 || true
  AAP_IP=$(port_ip "${PREFIX}-aap")

  FLOATING_IP=$(openstack floating ip create "$EXT_NET" -f value -c floating_ip_address)

  cat > "$OUT" <<JSON
{
  "net_id": "${NET_ID}",
  "manual_ip": "10.0.1.3",
  "allowed_address_pairs": "${AAP_IP}",
  "net_id_no_dhcp_1": "${NET_ID_ND1}",
  "no_dhcp_manual_ip_1": "10.1.1.3",
  "net_id_no_dhcp_2": "${NET_ID_ND2}",
  "no_dhcp_manual_ip_2": "10.2.1.3",
  "default_key_name": "${KEY_NAME}",
  "floating_ip": "${FLOATING_IP}",
  "security_group_id": "${SG_ID}",
  "security_group_name": "${SG_NAME}",
  "loadbalancer_pool_name": ""
}
JSON

elif [ "$TOPOLOGY" = "bats" ]; then
  # --- bats topology (modules/bats + bats-manual root) ----------------------
  # primary 10.0.4.0/24 (dhcp), secondary 10.0.5.0/24 (dhcp).
  # Allocate a floating IP for the director so create-env can reach the agent
  # via 172.24.4.x — always reachable from the host via br-ex without needing
  # host-route tricks.
  echo "=== networks (bats) ==="
  PRIMARY_ID=$(make_net   "${PREFIX}-primary"   "10.0.4.0/24" "10.0.4.1" yes yes)
  SECONDARY_ID=$(make_net "${PREFIX}-secondary" "10.0.5.0/24" "10.0.5.1" yes yes)

  # Allocate a floating IP for the director. The host reaches 172.24.4.x directly
  # via br-ex (DevStack always sets this up), so this is the reliable path for
  # create-env to reach the BOSH agent — no host-route tricks needed.
  DIRECTOR_FLOATING_IP=$(openstack floating ip create "$EXT_NET" -f value -c floating_ip_address)

  cat > "$OUT" <<JSON
{
  "director_public_ip": "${DIRECTOR_FLOATING_IP}",
  "director_private_ip": "10.0.4.3",
  "primary_net_id": "${PRIMARY_ID}",
  "primary_net_cidr": "10.0.4.0/24",
  "primary_net_gateway": "10.0.4.1",
  "primary_net_manual_ip": "10.0.4.4",
  "primary_net_second_manual_ip": "10.0.4.5",
  "primary_net_static_range": "10.0.4.4-10.0.4.100",
  "primary_net_dhcp_pool": "10.0.4.200-10.0.4.254",
  "secondary_net_id": "${SECONDARY_ID}",
  "secondary_net_cidr": "10.0.5.0/24",
  "secondary_net_gateway": "10.0.5.1",
  "secondary_net_manual_ip": "10.0.5.4",
  "secondary_net_static_range": "10.0.5.4-10.0.5.100",
  "secondary_net_dhcp_pool": "10.0.5.200-10.0.5.254",
  "dns": ["${DNS_NS}"],
  "openstack_project": "${PROJECT}",
  "default_key_name": "${KEY_NAME}",
  "security_group": "${SG_NAME}"
}
JSON

else
  echo "::error::unknown TOPOLOGY '${TOPOLOGY}' (expected lifecycle|bats)"; exit 1
fi

echo "=== ${OUT} ==="
cat "$OUT"
