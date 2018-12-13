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
#. What this is: Setup script for kubeflow on a user's workstation
#.
#. Prerequisites:
#. - Ubuntu Xenial or Centos 7 workstation
#. - Kubernetes cluster installed somewhere, with credentials allowing you to
#.   access it from your workstation shell
#. - Persistent Volume (PV) available in the k8s cluster, with null namespace
#. - Create and cd to a folder created where you want these tools to be installed
#. - kubectl setup per setup_kubectl.sh in this repo (see it for instructions)
#. - For OpenShift, use "oc login" first to log into a user account with
#.   cluster-admin privileges (this is a temporary workaround)
#. Usage:
#. - bash setup-kubeflow.sh <master> <username> <k8sdist> [clean] [force]
#.   master: k8s master hostname/IP
#.   username: username on the server where the master was installed (this is
#.     the user who setup the cluster, and for which key-based SSH is setup)
#.   k8sdist: k8s distribution, generic|openshift
#.   clean: stop kubeflow and remove related resources
#.   force: for clean, force deletion of resources (use if the namespace delete
#.     process just loops forever)

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

function setup_prereqs() {
  trap 'fail' ERR
  if [[ $(dpkg -l | grep -c kubectl) -eq 0 ]]; then
    log "Install kubectl"
    export KUBE_VERSION=1.10.0
    # Install kubectl per https://kubernetes.io/docs/setup/independent/install-kubeadm/
    sudo apt-get update && sudo apt-get install -y apt-transport-https
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    sudo apt-get update
    sudo apt-get -y install --allow-downgrades kubectl=${KUBE_VERSION}-00 
  fi

  rm -rf kubeflow
  rm -rf ks_0.13.1_linux_amd64*
  log "Install ksonnet to /usr/bin/ksonnet"
  # https://www.kubeflow.org/docs/started/getting-started/
  # ksonnet version 0.11.0 or later.
  wget -O ks_0.13.1_linux_amd64.tar.gz \
    https://github.com/ksonnet/ksonnet/releases/download/v0.13.1/ks_0.13.1_linux_amd64.tar.gz
  gzip -d ks_0.13.1_linux_amd64.tar.gz
  tar -xvf ks_0.13.1_linux_amd64.tar
  ls ks_0.13.1_linux_amd64
  sudo cp ks_0.13.1_linux_amd64/ks /usr/bin/.

  log "Download and run kfctl.sh"
  export KUBEFLOW_SRC=$WORK_DIR/kubeflow
  mkdir ${KUBEFLOW_SRC}
  cd ${KUBEFLOW_SRC}
  export KUBEFLOW_TAG=v0.3.4
  curl https://raw.githubusercontent.com/kubeflow/kubeflow/${KUBEFLOW_TAG}/scripts/download.sh | bash
}

function setup() {
  trap 'fail' ERR
  cd $WORK_DIR
  if [[ "$k8sdist" == "openshift" ]]; then
    log "Ensure OpenShift compatibility"
    # For OpenShift, relax default security restrictions first, as cluster-admin
    oc new-project kubeflow
    oc project kubeflow
    oc adm policy add-scc-to-user anyuid -z ambassador -n kubeflow
    oc adm policy add-scc-to-user anyuid -z jupyter-hub -n kubeflow
    oc adm policy add-role-to-user cluster-admin -z tf-job-operator -n kubeflow
    # vizier-core error: 1 proxy.go:41] listen tcp :80: bind: permission denied
    oc adm policy add-role-to-user cluster-admin system:serviceaccount:kubeflow:default
  fi

  log "Deploy kubeflow under k8s"
  log "Run ${KUBEFLOW_SRC}/scripts/kfctl.sh init"
  export KFAPP=~/kfapp
  # Workaround for bug in kfctl.sh
  # https://github.com/kubeflow/kubeflow/issues/2009
  sed -i 's/-d ${DEPLOYMENT_NAME}/! -d ${DEPLOYMENT_NAME}/' ${KUBEFLOW_SRC}/scripts/kfctl.sh
  ${KUBEFLOW_SRC}/scripts/kfctl.sh init ${KFAPP} --platform none
  cd ${KFAPP}
  log "Run ${KUBEFLOW_SRC}/scripts/kfctl.sh generate k8s"
  ${KUBEFLOW_SRC}/scripts/kfctl.sh generate k8s
  log "Run ${KUBEFLOW_SRC}/scripts/kfctl.sh apply k8s"
  ${KUBEFLOW_SRC}/scripts/kfctl.sh apply k8s

  if [[ "$k8sdist" == "openshift" ]]; then
 #   log "Remove restricted annotation from modeldb-db and modeldb-backend"
 #   pods="modeldb-db modeldb-backend"
 #   for pod in $pods; do
 #     p=""
 #     while [[ "$p" == "" ]]; do
 #       sleep 10
 #       p=$(kubectl get pod --namespace kubeflow | awk "/$pod/ {print \$1}")
 #     done
 #     kubectl annotate pods -n kubeflow $p openshift.io/scc-
 #   done
    log "Workaround write permission issue with vizier-db PV"
ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $username@$master <<'EOF'
sudo chmod 777 /home/centos/openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit/openshift.local.clusterup/openshift.local.pv/*
EOF
  fi

  log "Wait for all kubeflow pods to be Running"
  pods=$(kubectl get pods --namespace kubeflow | awk '/-/ {print $1}')
  for pod in $pods; do
    status=$(kubectl get pods -n kubeflow | awk "/$pod/ {print \$3}")
    while [[ "$status" != "Running" ]]; do
      log "$pod status is $status. Waiting 10 seconds"
      sleep 10
      status=$(kubectl get pods -n kubeflow | awk "/$pod/ {print \$3}")
    done
    log "$pod status is $status"
  done
}

function forward_ui() {
  trap 'fail' ERR
  log "Forward localhost ports to kubeflow dashboard, argo"
  # Per https://www.kubeflow.org/docs/guides/accessing-uis/
  nohup kubectl port-forward svc/ambassador 8080:80 &
  # Per https://github.com/argoproj/argo/blob/master/demo.md
  nohup kubectl port-forward svc/argo-ui 8081:80 &
}

clean() {
  log "Clean kubeflow install"
  kill $(ps -ef | awk '/port-forward/{print $2}' | head -1)
  kubectl delete namespace kubeflow $force
  while kubectl get namespace kubeflow; do
    echo "Waiting 10 seconds for namespace kubeflow to be deleted"
    sleep 10
  done
  rm -rf ~/kfapp
  rm -rf kubeflow
  rm -rf ks_0.13.1_linux_amd64*
}

export WORK_DIR=$(pwd)
dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
master=$1
username=$2
k8sdist=$3
if [[ "$4" == "clean" ]]; then
  if [[ "$5" == "force" ]]; then force='--force --grace-period=0'; fi
  clean
  trap '' ERR
  kubectl delete -f https://storage.googleapis.com/ml-pipeline/release/0.1.2/bootstrapper.yaml
  log "All done!"
  log "You can now redeploy kubeflow"
else
  setup_prereqs
  setup
  forward_ui
  log "All done!"
  echo "Kubeflow dashboard: http://localhost:8080"
  echo "Kubeflow pipelines: http://localhost:8080/pipeline/#/pipelines"
  echo "Argo: http://localhost:8081"
fi
cd $WORK_DIR
