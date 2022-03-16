#!/bin/bash
# ----------------------------------------------------------------------------
# Author : Dave Whitehouse
# Created: Date: 15 Mar 22
# Contact: @David Whitehouse
# Scope  : Spin up a kommander cluster in GCP using CAPI
# ---------------------------------------------------------------------------

info () {
  echo -e '\n\e[0;35m'$1'\e[0;37m\n'
}

# Set up our bootstrap cluster
info "Spinning up Bootstrap"
kind delete cluster
kind create cluster

# Set up config and gcloud creds
export GITHUB_TOKEN=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
export GCP_PROJECT_ID=architect-lab-d2iq
export GOOGLE_APPLICATION_CREDENTIALS=/home/dswhitehouse/capi/creds.pega.json
export GCP_REGION=europe-west2
export GCP_PROJECT=architect-lab-d2iq
export KUBERNETES_VERSION=v1.21.1
export GCP_CONTROL_PLANE_MACHINE_TYPE=e2-standard-4
export GCP_NODE_MACHINE_TYPE=e2-standard-8
export GCP_NETWORK_NAME=d2iq-network
export CLUSTER_NAME=architect-lab-d2iq
export IMAGE_ID="https://www.googleapis.com/compute/v1/projects/architect-lab-d2iq/global/images/cluster-api-ubuntu-1804-v1-21-10-1647440554"
export GCP_B64ENCODED_CREDENTIALS=$( cat /home/dswhitehouse/capi/creds.pega.json | base64 | tr -d '\n' )
export CONTROL_COUNT=1
export WORKER_COUNT=1
export CLUSTER_TOPOLOGY=true


# Install the GCP controller
info "Installing the GCP Controller"
clusterctl init --infrastructure gcp

# Wait for capg container to become available
while [ $(kubectl get po -A | grep -v Running | wc -l) -gt 1 ]; do
  clear
  info "Waiting for the controllers to be ready"
  kubectl get po -A
  sleep 10
done

info "Generating out cluster manifest"
clusterctl generate cluster $CLUSTER_NAME \
--kubernetes-version $KUBERNETES_VERSION \
--control-plane-machine-count=$CONTROL_COUNT \
--worker-machine-count=$WORKER_COUNT \
> $CLUSTER_NAME.yaml

kubectl apply -f $CLUSTER_NAME.yaml

# Check for initialised controlplane
while [ $(kubectl get kubeadmcontrolplane | grep true | wc -l) -lt 1 ]; do
  clear
  info "Waiting for the control plane to initialise. This will take a few minutes. I'll try again in 30s"
  kubectl get kubeadmcontrolplane
  sleep 30
done

# Snag the kubeconfig and set as default
info "Retrieving the config for our new cluster"
clusterctl get kubeconfig $CLUSTER_NAME > $CLUSTER_NAME.kubeconfig

# Install CNI and Cert Manager
info "Installing CNI and cert-manager"
kubectl apply -f https://docs.projectcalico.org/v3.21/manifests/calico.yaml --kubeconfig=$CLUSTER_NAME.kubeconfig
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.7.1/cert-manager.yaml --kubeconfig=$CLUSTER_NAME.kubeconfig

# Create a default StorageClass
info "Adding Storage"
cat <<EOF | kubectl apply -f --kubeconfig=$CLUSTER_NAME.kubeconfig -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gold
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/gce-pd
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: pd-ssd
  fstype: ext4
  replication-type: regional-pd
EOF

for node in $(kubectl get no --no-headers -o custom-columns=":metadata.name")
do
  kubectl label nodes $node topology.kubernetes.io/region=europe-west2
  kubectl label nodes $node topology.kubernetes.io/zone=europe-west2-a
done

# Move bootstrap controllers
info "Pivoting bootstrap controllers to the new cluster"
clusterctl init --infrastructure gcp --kubeconfig=$CLUSTER_NAME.kubeconfig
clusterctl move --to-kubeconfig=$CLUSTER_NAME.kubeconfig
export KUBECONFIG=$CLUSTER_NAME.kubeconfig

exit 0

# Install kommander
info "Starting Kommander install"
kommander install

# Wait for helm releases
sleep 30
declare -i COMPCOUNT=0
declare -i COMPREADY=0
while [[ $COMPREADY -lt $COMPCOUNT || $COMPCOUNT -lt 30 ]]; do
  clear
  COMPCOUNT=$(kubectl get helmreleases -n kommander | wc -l)-1   
  COMPREADY=$(kubectl get helmreleases -n kommander | grep True | wc -l )
  kubectl get helmreleases -n kommander 
  sleep 10
done

# Get our creds
info "Retrieving our login URL and credentials"
kubectl -n kommander get svc kommander-traefik -o go-template='https://{{with index .status.loadBalancer.ingress 0}}{{or .hostname .ip}}{{end}}/dkp/kommander/dashboard{{ "\n"}}'
kubectl -n kommander get secret dkp-credentials -o go-template='Username: {{.data.username|base64decode}}{{ "\n"}}Password: {{.data.password|base64decode}}{{ "\n"}}'

# Ditch the bootstrapper
info "Install complete. If you wish to destroy the bootstrap cluster, run 'kind delete cluster'"
# kind delete cluster
