# New bosh-lite cheat sheet

## log in to bosh

```sh
export BOSH_ENVIRONMENT=vbox
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$(bosh2 int ~/deployments/vbox/creds.yml --path /admin_password)
```

## ssh to bosh

```sh
bosh2 int ~/deployments/vbox/creds.yml --path /jumpbox_ssh/private_key > private_key

chmod 0600 private_key

ssh -i private_key jumpbox@192.168.50.6
```

## VirtualBox bosh-lite loses internet connectivity

Sometimes this happens after it is running for a while due to a VirtualBox bug.

```
VBoxManage natnetwork stop --netname NatNetwork
VBoxManage natnetwork start --netname NatNetwork
```

## Bringing back a dead bosh-lite

Upgrade VirtualBox to the latest version because it is more stable.

Make sure the bosh-lite VM is running in VirtualBox.

Edit `~/deployments/vbox/state.json` and remove the `current_manifest_sha` key.

Run `~/workspace/cli-workstation/scripts/deploy-cf/deploy_bosh_lite.sh`. This
will recreate the bosh-lite but not the containers.

`bosh2 delete-deployment -d cf`

Run `~/workspace/cli-workstation/scripts/deploy-cf/deploy_bosh_lite.sh` again
to recreate the cf deployment.