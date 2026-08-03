#!/usr/bin/env bash
# Provision the lifecycle-test network topology on DevStack using the openstack
# CLI, replacing the upstream terraform modules/lifecycle. Emits metadata.json
# with the exact keys that ci/tasks/run-lifecycle.sh reads via jq.
#
# Mirrors bosh-openstack-cpi-release/ci/terraform/ci/modules/{base,lifecycle}.
set -euo pipefail

PREFIX="${PREFIX:-lifecycle}"
EXT_NET="${EXT_NET:-public}"
DNS_NS="${DNS_NS:-8.8.8.8}"
PUBKEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"
OUT="${OUT:-metadata.json}"
mkdir -p "$(dirname "$OUT")"

# Networks (match modules/lifecycle CIDRs)
MAIN_CIDR="10.0.1.0/24";  MAIN_GW="10.0.1.1";  MAIN_MANUAL_IP="10.0.1.3"
NODHCP1_CIDR="10.1.1.0/24"; NODHCP1_GW="10.1.1.1"; NODHCP1_MANUAL_IP="10.1.1.3"
NODHCP2_CIDR="10.2.1.0/24"; NODHCP2_GW="10.2.1.1"; NODHCP2_MANUAL_IP="10.2.1.3"

PROJECT="${OS_PROJECT_NAME:-admin}"
KEY_NAME="${PREFIX}-${PROJECT}"

id_of() { openstack "$1" show "$2" -f value -c id; }

echo "=== keypair ${KEY_NAME} ==="
if [ ! -f "$PUBKEY_FILE" ]; then
  ssh-keygen -t rsa -b 2048 -N "" -f "${PUBKEY_FILE%.pub}"
fi
openstack keypair create --public-key "$PUBKEY_FILE" "$KEY_NAME" >/dev/null 2>&1 || \
  echo "keypair ${KEY_NAME} already exists"

echo "=== security group ${PREFIX} ==="
openstack security group create "$PREFIX" --description "cpi lifecycle tests" >/dev/null 2>&1 || true
SG_ID=$(id_of "security group" "$PREFIX")
SG_NAME="$PREFIX"

# intra-SG allow (tcp/udp/icmp), then SSH + BOSH agent/nats + DNS from anywhere
add_rule() { openstack security group rule create "$@" "$SG_ID" >/dev/null 2>&1 || true; }
add_rule --protocol tcp  --remote-group "$SG_ID"
add_rule --protocol udp  --remote-group "$SG_ID"
add_rule --protocol icmp --remote-group "$SG_ID"
add_rule --protocol tcp  --dst-port 22:22    --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 25555:25555 --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 6868:6868 --remote-ip 0.0.0.0/0
add_rule --protocol udp  --dst-port 53:53     --remote-ip 0.0.0.0/0
add_rule --protocol tcp  --dst-port 53:53     --remote-ip 0.0.0.0/0

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

echo "=== networks ==="
NET_ID=$(make_net "${PREFIX}"           "$MAIN_CIDR"    "$MAIN_GW"    yes yes)
NET_ID_ND1=$(make_net "${PREFIX}-no-dhcp-1" "$NODHCP1_CIDR" "$NODHCP1_GW" no  no)
NET_ID_ND2=$(make_net "${PREFIX}-no-dhcp-2" "$NODHCP2_CIDR" "$NODHCP2_GW" no  no)

echo "=== allowed-address-pairs port ==="
openstack port create --network "${PREFIX}" "${PREFIX}-aap" >/dev/null 2>&1 || true
AAP_IP=$(openstack port show "${PREFIX}-aap" -f json \
  | jq -r '.fixed_ips[0].ip_address // .fixed_ips' | sed -E "s/.*ip_address='([^']+)'.*/\1/")

echo "=== floating ip ==="
FLOATING_IP=$(openstack floating ip create "$EXT_NET" -f value -c floating_ip_address)

cat > "$OUT" <<JSON
{
  "net_id": "${NET_ID}",
  "manual_ip": "${MAIN_MANUAL_IP}",
  "allowed_address_pairs": "${AAP_IP}",
  "net_id_no_dhcp_1": "${NET_ID_ND1}",
  "no_dhcp_manual_ip_1": "${NODHCP1_MANUAL_IP}",
  "net_id_no_dhcp_2": "${NET_ID_ND2}",
  "no_dhcp_manual_ip_2": "${NODHCP2_MANUAL_IP}",
  "default_key_name": "${KEY_NAME}",
  "floating_ip": "${FLOATING_IP}",
  "security_group_id": "${SG_ID}",
  "security_group_name": "${SG_NAME}",
  "loadbalancer_pool_name": ""
}
JSON

echo "=== metadata.json ==="
cat "$OUT"
