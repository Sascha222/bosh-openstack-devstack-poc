#!/usr/bin/env bash
#
# Deploy a BOSH director on DevStack via `bosh create-env`, using a RELEASED
# bosh-openstack-cpi from bosh.io. Modeled on the upstream per-IaaS CI
# setup-director scripts (e.g. bosh-google-cpi-release ci/tasks/setup-director.sh):
# call create-env directly with bosh-deployment ops files + a tiny local-CPI ops
# file, rather than reusing the Concourse deploy-manual-networking.sh (which
# builds the CPI from source and dumps the interpolated manifest to the log).
#
# Required env (set by ci.yml):
#   OS_AUTH_URL
# Reads network facts from terraform-cpi/metadata (bats topology).
set -euxo pipefail

META=terraform-cpi/metadata
DEP=bosh-director-deployment
BOSH_DEPLOYMENT=bosh-deployment
CPI_RELEASE_URL="https://bosh.io/d/github.com/cloudfoundry/bosh-openstack-cpi-release"

mkdir -p "${DEP}"

echo "Downloading released bosh-openstack-cpi..."
wget -q "${CPI_RELEASE_URL}" -O "${DEP}/cpi.tgz"
echo "CPI downloaded."

# Local-artifact ops: released CPI + the stemcell we already downloaded.
cat > "${DEP}/ops_local_cpi.yml" <<EOF
- type: replace
  path: /releases/name=bosh-openstack-cpi?
  value:
    name: bosh-openstack-cpi
    url: file://${PWD}/${DEP}/cpi.tgz
EOF

cat > "${DEP}/ops_local_stemcell.yml" <<EOF
- type: replace
  path: /resource_pools/name=vms/stemcell?
  value:
    url: file://${PWD}/stemcell-director/stemcell.tgz
EOF

# bosh-deployment/openstack/cpi.yml hardcodes m1.xlarge (8vCPU/16GB) — too big
# for a single DevStack compute node on a CI runner.
cat > "${DEP}/ops_flavor.yml" <<EOF
- type: replace
  path: /resource_pools/name=vms/cloud_properties/instance_type
  value: m1.medium
EOF

NET_ID="$(jq -r .primary_net_id "${META}")"
SG="$(jq -r .security_group "${META}")"
GW="$(jq -r .primary_net_gateway "${META}")"
CIDR="$(jq -r .primary_net_cidr "${META}")"
INTERNAL_IP="$(jq -r .director_private_ip "${META}")"
EXTERNAL_IP="$(jq -r .director_public_ip "${META}")"
KEY_NAME="$(jq -r .default_key_name "${META}")"

echo "Deploying BOSH director: internal=${INTERNAL_IP} external=${EXTERNAL_IP}..."

# Background monitor: every 60s print VM state + console tail so we can see
# what the guest OS is doing while create-env polls for the agent.
_monitor() {
  while sleep 60; do
    echo "--- [monitor] VM list ---"
    openstack server list -f value -c ID -c Name -c Status -c Networks 2>/dev/null || true
    for vm_id in $(openstack server list -f value -c ID 2>/dev/null); do
      echo "--- [monitor] console log for ${vm_id} (last 20 lines) ---"
      openstack console log show "$vm_id" 2>/dev/null | tail -20 || true
      # Extract floating IP (172.24.x.x) and test port 6868
      EXT_IP=$(openstack server show "$vm_id" -f value -c addresses 2>/dev/null \
        | grep -oE '172\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      if [ -n "$EXT_IP" ]; then
        echo "--- [monitor] testing ${EXT_IP}:6868 ---"
        nc -z -w3 "$EXT_IP" 6868 2>&1 && echo "PORT OPEN" || echo "PORT CLOSED"
      fi
    done
  done
}
_monitor &
MONITOR_PID=$!
# shellcheck disable=SC2064
trap "kill $MONITOR_PID 2>/dev/null || true" EXIT

bosh create-env "${BOSH_DEPLOYMENT}/bosh.yml" \
  --state "${DEP}/state.json" \
  --vars-store "${DEP}/credentials.yml" \
  -o "${BOSH_DEPLOYMENT}/openstack/cpi.yml" \
  -o "${BOSH_DEPLOYMENT}/openstack/use-jammy.yml" \
  -o "${BOSH_DEPLOYMENT}/external-ip-not-recommended.yml" \
  -o "${BOSH_DEPLOYMENT}/jumpbox-user.yml" \
  -o "${DEP}/ops_local_cpi.yml" \
  -o "${DEP}/ops_local_stemcell.yml" \
  -o "${DEP}/ops_flavor.yml" \
  -v director_name=bosh \
  -v internal_ip="${INTERNAL_IP}" \
  -v external_ip="${EXTERNAL_IP}" \
  -v internal_gw="${GW}" \
  -v internal_cidr="${CIDR}" \
  -v net_id="${NET_ID}" \
  -v default_key_name="${KEY_NAME}" \
  -v "default_security_groups=[${SG}]" \
  -v auth_url="${OS_AUTH_URL}" \
  -v openstack_username=admin \
  -v openstack_password=secret \
  -v openstack_domain=Default \
  -v openstack_project=admin \
  -v region=RegionOne \
  -v az=nova

echo "Verifying director at ${EXTERNAL_IP}..."
BOSH_ENVIRONMENT="${EXTERNAL_IP}"
export BOSH_ENVIRONMENT
export BOSH_CLIENT=admin
BOSH_CLIENT_SECRET="$(bosh int "${DEP}/credentials.yml" --path /admin_password)"
echo "::add-mask::${BOSH_CLIENT_SECRET}"
export BOSH_CLIENT_SECRET
BOSH_CA_CERT="$(bosh int "${DEP}/credentials.yml" --path /director_ssl/ca)"
export BOSH_CA_CERT
bosh -n env
