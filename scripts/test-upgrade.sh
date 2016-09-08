#!/usr/bin/env bash
# Copyright 2014-2016, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# (c) 2015, Nolan Brubaker <nolan.brubaker@rackspace.com>
# (c) 2016, Matthew Thode <matt.thode@rackspace.com>

set -eux -o pipefail

BASE_DIR=$( cd "$( dirname ${0} )" && cd ../ && pwd )
OA_DIR="$BASE_DIR/openstack-ansible"
RPCD_DIR="$BASE_DIR/rpcd"

# Create a backup of /etc/openstack_deploy, if one doesn't already exist
# NOTE: This gets done by openstack-ansible's scripts/run-upgrade.sh script,
#       but if we wait until then it'll be too late.
if [[ ! -d "/etc/openstack_deploy.MITAKA" ]]; then
  cp -a /etc/openstack_deploy /etc/openstack_deploy.MITAKA
fi

# TASK #0
# Bug: https://github.com/rcbops/u-suk-dev/issues/347
# Issue: Variables files have been reorganized, run a migration script to move
#        them to the new location.
if [[ ! -f "/etc/openstack_deploy/user_rpco_variables_overrides.yml" ]]; then
  "${BASE_DIR}"/scripts/migrate-yaml.py --for-testing-take-new-vars-only \
      --defaults "${RPCD_DIR}"/etc/openstack_deploy/user_rpco_variables_defaults.yml \
      --overrides /etc/openstack_deploy/user_extras_variables.yml \
      --output-file /etc/openstack_deploy/user_rpco_variables_overrides.yml
fi
if [[ ! -f "/etc/openstack_deploy/user_osa_variables_overrides.yml" ]]; then
  "${BASE_DIR}"/scripts/migrate-yaml.py --for-testing-take-new-vars-only \
    --defaults "${RPCD_DIR}"/etc/openstack_deploy/user_osa_variables_defaults.yml \
    --overrides /etc/openstack_deploy/user_variables.yml \
    --output-file /etc/openstack_deploy/user_osa_variables_overrides.yml
fi
# TODO: We need to eventually find a proper way to migrate these secret variables.
#       For now, we just copy existing secret variables defined previously on the
#       liberty install. This won't cause any problems since there aren't any new
#       secret variables in mitaka that are not defined in liberty.
cp /etc/openstack_deploy/user_extras_secrets.yml \
   /etc/openstack_deploy/user_rpco_secrets.yml
cp -a ${RPCD_DIR}/etc/openstack_deploy/*defaults* /etc/openstack_deploy
rm /etc/openstack_deploy/user_extras_variables.yml \
   /etc/openstack_deploy/user_variables.yml        \
   /etc/openstack_deploy/user_extras_secrets.yml

# TASK #1
# Update Ansible
cd ${OA_DIR}
bash scripts/bootstrap-ansible.sh

# TASK #2
# Bug:   https://github.com/rcbops/u-suk-dev/issues/293
# Issue: We need to analyze support's maintenance plan to determine which
# pieces we can orchestrate with ansible. This should be added to a
# pre-upgrade task list.
cd ${RPCD_DIR}/playbooks
openstack-ansible rpc-pre-upgrades.yml

# TASK #3
# Bug: https://github.com/rcbops/u-suk-dev/issues/199
# Issue: To avoid any dependency issues that have occured in the past, the
#        repo_server containers are re-built. This was done as part of the
#        OSA upgrade script in liberty, but is not done in the OSA mitaka
#        upgrade script. Thus, we destroy the containers here.
cd ${OA_DIR}/playbooks
openstack-ansible lxc-containers-destroy.yml --limit repo_all
openstack-ansible setup-hosts.yml --limit repo_all

# TASK #4
# Bug:   https://github.com/rcbops/u-suk-dev/issues/374
# Issue: Neutron has no migration to correctly set the MTU on existing networks
#        created in liberty or below.  This work-around sets the MTU on these
#        networks before the upgrade starts so that instances booted on these
#        networks after the upgrade has finished will have their MTUs set
#        correctly.
# NOTE: In newton, MTUs will be calculated on the fly and this mtu field will
#       get dropped.
VLAN_FLAT="UPDATE networks SET mtu='1500' WHERE id IN (SELECT network_id FROM ml2_network_segments WHERE network_type IN ('vlan','flat'));"
VXLAN="UPDATE networks SET mtu='1450' WHERE id IN (SELECT network_id FROM ml2_network_segments WHERE network_type='vxlan');"

cd ${OA_DIR}/playbooks
ansible galera_all[0] -m shell -a "mysql --verbose -e \"${VLAN_FLAT}\" neutron"
ansible galera_all[0] -m shell -a "mysql --verbose -e \"${VXLAN}\" neutron"

# TASK #5
# https://github.com/rcbops/u-suk-dev/issues/392
# Upgrade openstack-ansible
pushd ${OA_DIR}
export I_REALLY_KNOW_WHAT_I_AM_DOING=true
echo "YES" | ${OA_DIR}/scripts/run-upgrade.sh
popd

# TASK #6
# https://github.com/rcbops/u-suk-dev/issues/393
# Run deploy.sh with MaaS and don't run the OSA playbooks.
# Ultimitely, this will run the RPCO playbooks.
cd ${BASE_DIR}
export DEPLOY_MAAS=${DEPLOY_MAAS:-'yes'}
export DEPLOY_OA='no'
export BOOTSTRAP_ANSIBLE='no'
bash scripts/deploy.sh

# TASK #7
# Bug: https://github.com/rcbops/u-suk-dev/issues/366
# Description: Run post-upgrade tasks.
#              For a detailed description, please see the README in
#              the rpc_post_upgrade role directory.
cd ${RPCD_DIR}/playbooks
openstack-ansible rpc-post-upgrades.yml
