# Spin up a Kommander Cluster in Google Cloud Platform (GCP) using Image Builder and Cluster API (CAPI)

## References:
* [The Cluster API Book](https://cluster-api.sigs.k8s.io/introduction.html)
* [The Image Builder Book](https://image-builder.sigs.k8s.io/introduction.html)
* [Kommander Docs](https://docs.d2iq.com/dkp/kommander/2.1/install/networked/)

## tldr:
If you can't be arsed to read or simply want a quick start, see automated script at the bottom of this document.

## Introduction:

DKP (currently v2.1) supports cluster deployment to AWS and Azure using cluster API.  This is a proven, repeatable and supported path. If however you want to deploy similarly to the Google Cloud, here is a simple way to use Kubernetes Image Builder (an image builder using packer and ansible) and Cluster API to get the job done. It is not supported, documented, validated etc so use with caution.

## Pre-requisites:

Ensure the following packages are installed on your local machine:
* [Gcloud CLI](https://cloud.google.com/sdk/docs/install#mac)
* [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
* [Packer](https://learn.hashicorp.com/tutorials/packer/get-started-install-cli)
* [Kubectl](https://dl.k8s.io/release/v1.23.4/bin/linux/amd64/kubectl)
* [Clusterctl](https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.1.2/clusterctl-linux-amd64)
* [Kommander](https://support.d2iq.com/hc/en-us/articles/4409215222932-Product-Downloads)
* [Kubernetes Image Builder](https://github.com/kubernetes-sigs/image-builder/tarball/master)
* [Docker](https://docs.docker.com/engine/install/)
* [KIND](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)

## Getting GCP Credentials

1. You may need to raise a ticket to gain access to the GCP Account.

2. With that done, head to the IAM API and select "Service Accounts" as follows:

![](https://i.imgur.com/w091oz4.png =400x)

3. Now generate a token using the default service account:

![](https://i.imgur.com/1PIMNil.png =800x)

4. Select format as "json". This will download the token to your local machine. Keep it secure as these are your credentials for access to the platform.

5. Rename the json file to creds.json for simplicity

```bash=
mv konvoy-gcp-se-*.json creds.json  
```

## Image Builder

In order to deploy a cluster using CAPI, we will need an template image. This is simply an image that is created in the preferred flavour of linux with all the pre-requisite configuration already done so that CAPI can deploy it as a cookie cutter to roll out nodes.

#### Use Existing Image:

![](https://i.imgur.com/ITXH2U5.jpg =18x) There may already be an image built to match your needs (obvious security common dog applies; do not use publicly available images). Check your organisation for existing images by running:

```bash=
gcloud auth login                       # Log into GCP from the terminal
export GCP_PROJECT_ID=konvoy-gcp-se     # The D2 default project
gcloud compute images list --project ${GCP_PROJECT_ID} --no-standard-images
```
May Yield:

```
NAME                                         PROJECT        FAMILY                      DEPRECATED  STATUS
cluster-api-ubuntu-2004-v1-21-10-1647095856  konvoy-gcp-se  capi-ubuntu-2004-k8s-v1-21              READY
```

You may see that there is an ubuntu image already built, privately in our project. Should you wish to use it, snag the uri and set the it as an env variable:

```bash=
export IMAGE_ID=$(gcloud compute images list --project ${GCP_PROJECT_ID} --no-standard-images --uri)
```

#### Build an Image:

First we need to get the image builder and set some env variables:

```bash=
# Export the GCP project id if you've not already done so
export GCP_PROJECT_ID=konvoy-gcp-se

# Export the path to our creds
export GOOGLE_APPLICATION_CREDENTIALS=creds.json

# Clone Image Builder
$ git clone https://github.com/kubernetes-sigs/image-builder.git
$ cd image-builder/images/capi/

# Run the target make deps-gce to install ansible and packer
$ make deps-gce
```

Then we'll build the image. The current make file has versions 1804 and 2004 of Ubuntu currently. Build our image as follows:

```bash=
make build-gce-ubuntu-1804       # Builds Ubuntu 1804
```

Then we will build the image in GCE. This will build an instance and run a number of playbooks to make it K8S ready. It will then export the images and finally kill the instance. This should take around 8 to 15 mins normally.

If this runs successfully, you can then refer to "Use Existing Image" section above to get our URI and set our IMAGE_ID env variable.


---

# Deploy a Cluster

We will use CAPI to deploy our cluster as follows:

1. Spin up our single node bootstrap cluster with KIND:

```bash=
kind delete cluster           # Ensure we destroy any previous cluster
kind create cluster           # Spin up a single node bootstrap in Docker
```
2. Set our env variables

```bash=
export GCP_PROJECT_ID=konvoy-gcp-se
export GOOGLE_APPLICATION_CREDENTIALS=$PWD/creds.json
export GCP_REGION=us-central1
export GCP_PROJECT=konvoy-gcp-se                            
# Make sure K8S version matches our Kommander pre-reqs
export KUBERNETES_VERSION=1.21.1
export GCP_CONTROL_PLANE_MACHINE_TYPE=e2-standard-4
export GCP_NODE_MACHINE_TYPE=e2-standard-8
# You may use the default network but not recommended
export GCP_NETWORK_NAME=my-cluster-name
export CLUSTER_NAME=my-cluster-name
export IMAGE_ID="https://www.googleapis.com/compute/v1/projects/konvoy-gcp-se/global/images/cluster-api-ubuntu-2004-v1-21-10-1647095856"
export GCP_B64ENCODED_CREDENTIALS=$( cat $PWD/creds.json | base64 | tr -d '\n' )
export CONTROL_COUNT=3
export WORKER_COUNT=4
```

3. Set up our GCP Controller in the bootstrap

```bash=
clusterctl init --infrastructure gcp
```

4. Ensure all controller pods are running. Watch the pods until the capg controller is running in the capg-system namespace. This will manage our deployment to GCP so its logs are of particular interest:

```bash=
watch -d "kubectl get po -n capg-system"
```

5. Generate the cluster manifest. A dry run is recommended:

```bash=
clusterctl generate cluster $CLUSTER_NAME \
--kubernetes-version $KUBERNETES_VERSION \
--control-plane-machine-count=$CONTROL_COUNT \
--worker-machine-count=$WORKER_COUNT \
> $CLUSTER_NAME.yaml
```

6. Examine, edit and then apply the cluster manifest:

```bash=
kubectl apply -f $CLUSTER_NAME.yaml
```

7. Wait for the control plane to initialise and present in the 'ready' state:

```bash=
watch -d "kubectl get kubeadmcontrolplane"
```

8. Get our kubeconfig file for our new cluster and set to default:

```bash=
clusterctl get kubeconfig $CLUSTER_NAME > $CLUSTER_NAME.kubeconfig
export KUBECONFIG=$CLUSTER_NAME.kubeconfig
```

9. Install our CNI and Cert Manager. Our CNI does not ship out of the box so it will need to be installed before networking will function. We will also need to install cert-manager prior to deploying Kommander so let's do it now. We'll use Calico:

```bash=
kubectl apply -f https://docs.projectcalico.org/v3.21/manifests/calico.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.7.1/cert-manager.yaml
```

10. We will need to provision some storage. In this instance we'll use the gce-pd class for persistent storage. More info may be found [here](https://kubernetes.io/docs/concepts/storage/storage-classes/#gce-pd). We'll apply a simple manifest with volume expansion and set it to default by actioning the following:

```bash=
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gold
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/gce-pd
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: pd-standard
  fstype: ext4
  replication-type: none
EOF
```

11. Add some additional labels to our nodes to ensure volume claims will work. Adjust for your regions and zones to taste:

```bash=
for node in $(kubectl get no --no-headers -o custom-columns=":metadata.name")
do
  kubectl label nodes $node topology.kubernetes.io/region=us-central1
  kubectl label nodes $node topology.kubernetes.io/zone=us-central1-c
done
```

12. Move our bootstrap controllers to our new management cluster.  This allows us to use the new cluster as a management plane to instantiate and manage new clusters and to shut down our KIND bootstrapper on the local machine:

```bash=
clusterctl init --infrastructure gcp --kubeconfig=$CLUSTER_NAME.kubeconf
clusterctl move --from-kubeconfig=~/.kube/config --to-kubeconfig=$CLUSTER_NAME.kubeconf

```


---
# Install Kommander
13. Install Kommander. Dry run and inspection recommended:

```bash=
kommander install --init > kommander.yaml
kommander install --config kommander.yaml
```

14. Observe Helm Releases. It will take up to 15 mins to install Kommander helm charts. Observe progress with the following command:

```bash=
watch -d "kubectl get helmreleases -n kommander"
```

15. Extract our URL and creds:

```bash=
kubectl -n kommander get svc kommander-traefik -o go-template='https://{{with index .status.loadBalancer.ingress 0}}{{or .hostname .ip}}{{end}}/dkp/kommander/dashboard{{ "\n"}}'
kubectl -n kommander get secret dkp-credentials -o go-template='Username: {{.data.username|base64decode}}{{ "\n"}}Password: {{.data.password|base64decode}}{{ "\n"}}'
```


---

# Troubleshooting

#### Kommander fails to install gitea:

![](https://i.imgur.com/GaDUC4b.gif =16x) This is likely caused by a node affinity. Check all pods in the 'kommander' space for 
a failure. If this is the case, examine the cause of failure with:

```bash=
kubectl describe pods -n kommander gitea-0
```
```
0/2 nodes are available: 1 node(s) had taint {node-role.kubernetes.io/master: }, that the pod didn't tolerate, 1 node(s) had volume node affinity conflict.
```
In our case we experienced a node affinity conflict. Check volume claims and nodes to ensure the correct labels are applied. See "Deploy" paragraph step 11.

#TODO
* permissions
* zone resource depletion
* CNI
* helm chart timeout
* wrong URI for image
* No image


---

# TLDR

Here's a script to cover all the steps above. You will need as a minimum (see initial paragraphs):
- [ ] Pre-req installs in place.
- [ ] Service account token.
- [ ] An image.

```bash=
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
export GCP_PROJECT_ID=konvoy-gcp-se
export GOOGLE_APPLICATION_CREDENTIALS=$PWD/creds.json
export GCP_REGION=us-central1
export GCP_PROJECT=konvoy-gcp-se
export KUBERNETES_VERSION=1.21.1
export GCP_CONTROL_PLANE_MACHINE_TYPE=e2-standard-4
export GCP_NODE_MACHINE_TYPE=e2-standard-8
export GCP_NETWORK_NAME=whitehouse-capi-test
export CLUSTER_NAME=whitehouse-capi-test
export IMAGE_ID="https://www.googleapis.com/compute/v1/projects/konvoy-gcp-se/global/images/cluster-api-ubuntu-2004-v1-21-10-1647095856"
export GCP_B64ENCODED_CREDENTIALS=$( cat $PWD/creds.json | base64 | tr -d '\n' )
export CONTROL_COUNT=1
export WORKER_COUNT=1

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
| kubectl apply -f -

# Check for initialised controlplane
while [ $(kubectl get kubeadmcontrolplane | grep true | wc -l) -lt 1 ]; do
  clear
  info "Waiting for the control plane to initialise. This may take a few minutes. I'll try again in 30s"
  kubectl get kubeadmcontrolplane
  sleep 30
done

# Snag the kubeconfig and set as default
info "Retrieving the config for our new cluster"
clusterctl get kubeconfig $CLUSTER_NAME > $CLUSTER_NAME.kubeconfig


# Install CNI and Cert Manager
info "Installing networking and certificate manager"
kubectl apply -f https://docs.projectcalico.org/v3.21/manifests/calico.yaml --kubeconfig=$CLUSTER_NAME.kubeconfig
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.7.1/cert-manager.yaml --kubeconfig=$CLUSTER_NAME.kubeconfig

# Create a default StorageClass
info "Adding Storage"
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gold
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/gce-pd
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: pd-standard
  fstype: ext4
  replication-type: none
EOF

# for node in $(kubectl get no --no-headers -o custom-columns=":metadata.name")
# do
#   kubectl label nodes $node topology.kubernetes.io/region=us-central1
#   kubectl label nodes $node topology.kubernetes.io/zone=us-central1-c
# done

# Move bootstrap controllers
info "Pivoting bootstrap controllers to the new cluster"
clusterctl init --infrastructure gcp --kubeconfig=$CLUSTER_NAME.kubeconfig
clusterctl move --to-kubeconfig=$CLUSTER_NAME.kubeconfig
export KUBECONFIG=$CLUSTER_NAME.kubeconfig

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

```