#!/bin/bash
# ===============LICENSE_START=======================================================
# Acumos Apache-2.0
# ===================================================================================
# Copyright (C) 2018 AT&T Intellectual Property. All rights reserved.
# ===================================================================================
# This Acumos software file is distributed by AT&T
# under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# This file is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===============LICENSE_END=========================================================
#
#. What this is: script to setup host-mapped PVs under kubernetes
#.
#. Prerequisites:
#. - k8s cluster
#. - key-based SSH setup between the workstation and k8s master node
#.
#. Usage: on the workstation,
#. $ bash setup-pv.sh <master> <username> [clean]
#.   master: IP address or hostname of k8s master node
#.   username: username on the server where the master was installed (this is
#.     the user who setup the cluster, and for which key-based SSH is setup)
#.   clean: remove the PV and related configuration
#.

trap 'fail' ERR

function fail() {
  log "$1"
  exit 1
}

function log() {
  fname=$(caller 0 | awk '{print $2}')
  fline=$(caller 0 | awk '{print $1}')
  echo; echo "$fname:$fline ($(date)) $1"
}

function setup() {
  # Per https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $username@$master <<'EOF'
pvs="1 2 3 4 5 6 7 8 9 10"
for pv in $pvs; do
  sudo mkdir /mnt/$pv
  dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
  if [[ "$dist" == "ubuntu" ]]; then
    sudo chown ubuntu:users /mnt/$pv
  else
    sudo chown centos:users /mnt/$pv
  fi
  cat <<EOG >pv-$pv.yaml
kind: PersistentVolume
apiVersion: v1
metadata:
  name: pv-$pv
  labels:
    type: local
spec:
  persistentVolumeReclaimPolicy: Recycle
  storageClassName:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/mnt/$pv"
EOG
  kubectl create -f pv-$pv.yaml
  kubectl get pv pv-$pv
done
EOF
}

function clean() {
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $username@$master <<'EOF'
pvcs=$(kubectl get pvc -n kubeflow | awk '/Gi/{print $1}')
for pvc in $pvcs; do
  kubectl delete pvc -n kubeflow $pvc
done
pvs="1 2 3 4 5"
for pv in $pvs; do
  kubectl delete pv pv-$pv
  rm pv-$pv.yaml
  sudo rm -rf /mnt/$pv
done
EOF
}

export WORK_DIR=$(pwd)
master=$1
username=$2

if [[ "$3" == "clean" ]]; then
  clean
else
  setup
fi

cd $WORK_DIR
