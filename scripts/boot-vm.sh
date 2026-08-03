#!/usr/bin/env bash
#
# Boot one VM through the freshly-deployed BOSH director, to exercise the full
# director-driven create_stemcell + create_vm path. Reads director creds from
# the create-env vars-store and network facts from terraform-cpi/metadata.
set -euxo pipefail

DIR=bosh-director-deployment
META=terraform-cpi/metadata

BOSH_ENVIRONMENT="$(jq -r .director_public_ip "${META}")"
export BOSH_ENVIRONMENT
export BOSH_CLIENT=admin
BOSH_CLIENT_SECRET="$(bosh int "${DIR}/credentials.yml" --path /admin_password)"
echo "::add-mask::${BOSH_CLIENT_SECRET}"
export BOSH_CLIENT_SECRET
BOSH_CA_CERT="$(bosh int "${DIR}/credentials.yml" --path /director_ssl/ca)"
export BOSH_CA_CERT

bosh -n env

# Upload the stemcell via the director/CPI (real create_stemcell path).
bosh -n upload-stemcell stemcell-director/stemcell.tgz

NET_ID="$(jq -r .primary_net_id "${META}")"
SG="$(jq -r .security_group "${META}")"

cat > cloud-config.yml <<EOF
azs: [{name: z1}]
vm_types: [{name: default, cloud_properties: {instance_type: m1.small}}]
disk_types: [{name: default, disk_size: 3000}]
compilation: {workers: 1, az: z1, vm_type: default, network: private, reuse_compilation_vms: true}
networks:
- name: private
  type: manual
  subnets:
  - range: 10.0.4.0/24
    gateway: 10.0.4.1
    azs: [z1]
    dns: [8.8.8.8]
    reserved: [10.0.4.2-10.0.4.10]
    static: [10.0.4.20-10.0.4.30]
    cloud_properties: {net_id: ${NET_ID}, security_groups: [${SG}]}
EOF
bosh -n update-cloud-config cloud-config.yml

# One instance that just boots the stemcell (no jobs/releases).
cat > manifest.yml <<EOF
name: smoke
stemcells: [{alias: default, os: ubuntu-jammy, version: latest}]
releases: []
instance_groups:
- name: nothing
  instances: 1
  azs: [z1]
  vm_type: default
  stemcell: default
  networks: [{name: private, default: [dns, gateway]}]
  jobs: []
update: {canaries: 1, max_in_flight: 1, canary_watch_time: 30000-600000, update_watch_time: 30000-600000}
EOF
bosh -n -d smoke deploy manifest.yml
bosh -d smoke instances --details
