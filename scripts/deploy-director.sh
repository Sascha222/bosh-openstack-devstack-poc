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
#   OS_AUTH_URL, director flavor/timeouts, etc. via the vars below.
# Reads network facts from terraform-cpi/metadata (bats topology).
set -euo pipefail

META=terraform-cpi/metadata
DEP=bosh-director-deployment
BOSH_DEPLOYMENT=bosh-deployment
CPI_RELEASE_URL="https://bosh.io/d/github.com/cloudfoundry/bosh-openstack-cpi-release"

mkdir -p "${DEP}"

echo "Downloading released bosh-openstack-cpi..."
wget -q "${CPI_RELEASE_URL}" -O "${DEP}/cpi.tgz"

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

NET_ID="$(jq -r .primary_net_id "${META}")"
SG="$(jq -r .security_group "${META}")"
GW="$(jq -r .primary_net_gateway "${META}")"
CIDR="$(jq -r .primary_net_cidr "${META}")"
INTERNAL_IP="$(jq -r .director_private_ip "${META}")"
KEY_NAME="$(jq -r .default_key_name "${META}")"

echo "Deploying BOSH director (create-env)..."
bosh create-env "${BOSH_DEPLOYMENT}/bosh.yml" \
  --state "${DEP}/state.json" \
  --vars-store "${DEP}/credentials.yml" \
  -o "${BOSH_DEPLOYMENT}/openstack/cpi.yml" \
  -o "${BOSH_DEPLOYMENT}/openstack/use-jammy.yml" \
  -o "${BOSH_DEPLOYMENT}/jumpbox-user.yml" \
  -o "${DEP}/ops_local_cpi.yml" \
  -o "${DEP}/ops_local_stemcell.yml" \
  -v director_name=bosh \
  -v internal_ip="${INTERNAL_IP}" \
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
  -v az=z1

echo "Verifying director..."
export BOSH_ENVIRONMENT="${INTERNAL_IP}"
export BOSH_CLIENT=admin
BOSH_CLIENT_SECRET="$(bosh int "${DEP}/credentials.yml" --path /admin_password)"
echo "::add-mask::${BOSH_CLIENT_SECRET}"
export BOSH_CLIENT_SECRET
export BOSH_CA_CERT="$(bosh int "${DEP}/credentials.yml" --path /director_ssl/ca)"
bosh -n env
