#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# exit on any error
set -e


MINION_IP=$3
MINION_ID=$2
DOCKER_BRIDGE=kbr0
OVS_SWITCH=obr0
GRE_TUNNEL_BASE=gre
BRIDGE_BASE=10.244
BRIDGE_ADDRESS=${BRIDGE_BASE}.${MINION_ID}.1
BRIDGE_NETWORK=${BRIDGE_ADDRESS}/24
BRIDGE_NETMASK=255.255.255.0
NETWORK_CONF_PATH=/etc/sysconfig/network-scripts/
POST_NETWORK_SCRIPT_DIR=/kubernetes-vagrant
POST_NETWORK_SCRIPT=${POST_NETWORK_SCRIPT_DIR}/network_closure.sh

# ensure location of POST_NETWORK_SCRIPT exists
mkdir -p $POST_NETWORK_SCRIPT_DIR

# add docker bridge ifcfg file
cat <<EOF > ${NETWORK_CONF_PATH}ifcfg-${DOCKER_BRIDGE}
# Generated by yours truly
DEVICE=${DOCKER_BRIDGE}
ONBOOT=yes
TYPE=Bridge
BOOTPROTO=static
IPADDR=${BRIDGE_ADDRESS}
NETMASK=${BRIDGE_NETMASK}
STP=no
EOF

# add the ovs bridge ifcfg file
cat <<EOF > ${NETWORK_CONF_PATH}ifcfg-${OVS_SWITCH}
DEVICE=${OVS_SWITCH}
ONBOOT=yes
DEVICETYPE=ovs
TYPE=OVSBridge
BOOTPROTO=static
HOTPLUG=no
BRIDGE=${DOCKER_BRIDGE}
EOF

# now loop through all other minions and create persistent gre tunnels
MINION_IPS=$5
MINION_IP_ARRAY=(`echo ${MINION_IPS} | tr "," "\n"`)

echo MINION_IP_ARRAY=$MINION_IP_ARRAY

GRE_NUM=0
for remote_ip in "${MINION_IP_ARRAY[@]}"
do
    if [ "${remote_ip}" == "${MINION_IP}" ]; then
         continue
    fi
    ((GRE_NUM++)) || echo
    GRE_TUNNEL=${GRE_TUNNEL_BASE}${GRE_NUM}
    # ovs-vsctl add-port ${OVS_SWITCH} ${GRE_TUNNEL} -- set interface ${GRE_TUNNEL} type=gre options:remote_ip=${remote_ip}
    cat <<EOF >  ${NETWORK_CONF_PATH}ifcfg-${GRE_TUNNEL}
DEVICE=${GRE_TUNNEL}
ONBOOT=yes
DEVICETYPE=ovs
TYPE=OVSTunnel
OVS_BRIDGE=${OVS_SWITCH}
OVS_TUNNEL_TYPE=gre
OVS_TUNNEL_OPTIONS="options:remote_ip=${remote_ip}"
EOF
done

# add ip route rules such that all pod traffic flows through docker bridge and consequently to the gre tunnels
cat <<EOF > /${NETWORK_CONF_PATH}route-${DOCKER_BRIDGE}
${BRIDGE_BASE}.0.0/16 dev ${DOCKER_BRIDGE} scope link src ${BRIDGE_ADDRESS}
EOF

# generate the post-configure script to be called by salt as cmd.wait
cat <<EOF > ${POST_NETWORK_SCRIPT}
#!/bin/bash

set -e

# Only do this operation once, otherwise, we get docker.servicee files output on disk, and the command line arguments get applied multiple times
grep -q kbr0 /etc/sysconfig/docker || {
  # Stop docker before making these updates
  systemctl stop docker

  # NAT interface fails to revive on network restart, so OR-gate to true
  systemctl restart network.service || true

  # set docker bridge up, and set stp on the ovs bridge
  ip link set dev ${DOCKER_BRIDGE} up
  ovs-vsctl set Bridge ${OVS_SWITCH} stp_enable=true

  # modify the docker service file such that it uses the kube docker bridge and not its own
  echo "OPTIONS='-b=kbr0 --selinux-enabled -H 0.0.0.0:2375 -H unix:///var/run/docker.sock --insecure-registry jadetest.cn.ibm.com:5000'" >/etc/sysconfig/docker
  systemctl daemon-reload
  systemctl restart docker.service

  # setup iptables masquerade rules so the pods can reach the internet
  iptables -t nat -A POSTROUTING -s ${BRIDGE_BASE}.0.0/16 ! -d ${BRIDGE_BASE}.0.0/16 -j MASQUERADE

  # persist please
  iptables-save >& /etc/sysconfig/iptables

}
EOF

chmod +x ${POST_NETWORK_SCRIPT}
