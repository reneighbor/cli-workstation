#!/bin/bash

if [[ $1 == "clean" ]]; then
  echo "removing old bosh lite"
  rm -rf $HOME/deployments/vbox
  vboxmanage list vms | awk '{print $1}' | tr -d '"'| grep -e ^sc- -e ^vm- | xargs -r -n 1 vboxmanage unregistervm --delete
fi # deletion can be a bit flaky, error handle after

set -e

export BOSH_CLIENT=admin
export BOSH_ENVIRONMENT=192.168.50.6

pushd ~/workspace
  if [ ! -d bosh-deployment ]; then
    git clone https://github.com/cloudfoundry/bosh-deployment.git
  fi
  pushd bosh-deployment
    git pull
  popd

  if [ ! -d cf-deployment ]; then
    git clone https://github.com/cloudfoundry/cf-deployment.git
  fi
  pushd cf-deployment
    git checkout master
    git pull
  popd
popd

CLI_OPS_DIR=~/workspace/cli-lite-ops
CLI_VARS_DIR=~/workspace/cli-lite-vars
BOSH_DEPLOYMENT=~/workspace/bosh-deployment
CF_DEPLOYMENT=~/workspace/cf-deployment
BOSH_RUNTIME_DIR=~/deployments/vbox

mkdir -p $CLI_OPS_DIR
mkdir -p $CLI_VARS_DIR

cat << EOF > $CLI_OPS_DIR/bosh-lite-more-power.yml
- type: replace
  path: /resource_pools/name=vms/cloud_properties/cpus
  value: 8

- type: replace
  path: /resource_pools/name=vms/cloud_properties/memory
  value: 8192
EOF

mkdir -p $BOSH_RUNTIME_DIR

cd $BOSH_RUNTIME_DIR

bosh -n create-env --recreate $BOSH_DEPLOYMENT/bosh.yml \
  --state ./state.json \
  -o $BOSH_DEPLOYMENT/virtualbox/cpi.yml \
  -o $BOSH_DEPLOYMENT/virtualbox/outbound-network.yml \
  -o $BOSH_DEPLOYMENT/bosh-lite.yml \
  -o $BOSH_DEPLOYMENT/bosh-lite-runc.yml \
  -o $BOSH_DEPLOYMENT/jumpbox-user.yml \
  -o $CLI_OPS_DIR/bosh-lite-more-power.yml \
  --vars-store $CLI_VARS_DIR/creds.yml \
  -v director_name="Bosh Lite Director" \
  -v internal_ip=$BOSH_ENVIRONMENT \
  -v internal_gw=192.168.50.1 \
  -v internal_cidr=192.168.50.0/24 \
  -v outbound_network_name=NatNetwork

bosh \
  --ca-cert <(bosh int $CLI_VARS_DIR/creds.yml --path /director_ssl/ca) \
  alias-env vbox

export BOSH_CLIENT_SECRET=`bosh int $CLI_VARS_DIR/creds.yml --path /admin_password`

bosh -e vbox -n update-runtime-config $BOSH_DEPLOYMENT/runtime-configs/dns.yml --vars-store=$CLI_VARS_DIR/runtime-config-vars.yml --name=dns

CFD_STEMCELL_VERSION="$(bosh int $CF_DEPLOYMENT/cf-deployment.yml --path /stemcells/alias=default/version)"
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-trusty-go_agent?v=$CFD_STEMCELL_VERSION

cat << EOF > $CLI_OPS_DIR/bosh-lite-internet-required.yml
- type: replace
  path: /vm_extensions/-
  value:
    name:
      internet-required
EOF

cd $CF_DEPLOYMENT/iaas-support/bosh-lite

bosh \
  -n \
  update-cloud-config cloud-config.yml \
  -o $CLI_OPS_DIR/bosh-lite-internet-required.yml

cd $CF_DEPLOYMENT

cat << EOF > $CLI_OPS_DIR/cli-bosh-lite.yml
- type: replace
  path: /instance_groups/name=api/jobs/name=cloud_controller_ng/properties/cc/default_app_memory?
  value: 32
- type: replace
  path: /instance_groups/name=api/jobs/name=cloud_controller_ng/properties/dea_next?
  value:
    staging_memory_limit_mb: 128
    staging_disk_limit_mb: 1024

- type: replace
  path: /instance_groups/name=api/jobs/name=cloud_controller_ng/properties/cc/diego?/temporary_local_tps
  value: true
EOF

cat << EOF > $CLI_OPS_DIR/cli-bosh-lite-uaa-client-credentials.yml
---
- type: replace
  path: /instance_groups/name=uaa/jobs/name=uaa/properties/uaa/clients/potato-face?
  value:
    access-token-validity: 60
    authorized-grant-types: client_credentials
    override: true
    secret: acute
    scope: openid,routing.router_groups.write,scim.read,cloud_controller.admin,uaa.user,routing.router_groups.read,cloud_controller.read,password.write,cloud_controller.write,network.admin,doppler.firehose,scim.write
    authorities: openid,routing.router_groups.write,scim.read,cloud_controller.admin,uaa.user,routing.router_groups.read,cloud_controller.read,password.write,cloud_controller.write,network.admin,doppler.firehose,scim.write
EOF

cat << EOF > $CLI_OPS_DIR/enable-MFA.yml
---
- type: replace
  path: /instance_groups/name=uaa/jobs/name=uaa/properties/login/mfa?
  value:
    enabled: true
    providerName: potato
    providers:
      potato:
	type: google-authenticator
	config:
	  providerDescription: test google authenticator
	  issuer: google
EOF

cat << EOF > $CLI_OPS_DIR/disable-rep-kernel-params.yml
---
- type: replace
  path: /instance_groups/name=isolated-diego-cell/jobs/name=rep/properties?/set_kernel_parameters
  value: false
EOF

bosh \
  -n \
  -d cf deploy cf-deployment.yml \
  -o operations/use-compiled-releases.yml \
  -o operations/bosh-lite.yml \
  -o operations/test/add-persistent-isolation-segment-diego-cell.yml \
  -o operations/experimental/fast-deploy-with-downtime-and-danger.yml \
  -o $CLI_OPS_DIR/cli-bosh-lite.yml \
  -o $CLI_OPS_DIR/cli-bosh-lite-uaa-client-credentials.yml \
  -o $CLI_OPS_DIR/disable-rep-kernel-params.yml \
  --vars-store $CLI_VARS_DIR/deployment-vars.yml \
  -v system_domain=bosh-lite.com \
  -v cf_admin_password=admin

BOSH_LITE_NETWORK=10.244.0.0
BOSH_LITE_NETMASK=255.255.0.0

# Set up virtualbox IP as the gateway to our CF
if ! route | egrep -q "$BOSH_LITE_NETWORK\\s+$BOSH_ENVIRONMENT\\s+$BOSH_LITE_NETMASK\\s"; then
  sudo route add -net $BOSH_LITE_NETWORK netmask $BOSH_LITE_NETMASK gw $BOSH_ENVIRONMENT
fi

cf api api.bosh-lite.com --skip-ssl-validation
cf auth admin admin
cf enable-feature-flag diego_docker
