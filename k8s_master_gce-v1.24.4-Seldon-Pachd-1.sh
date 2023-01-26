#!/bin/bash

echo "\$nrconf{restart} = 'a';" | sudo tee -a /etc/needrestart/needrestart.conf
apt-get update
apt-get install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y      
curl -fsSL https://download.docker.com/linux/ubuntu/gpg |  gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce containerd.io docker-ce-cli


#Configure iptables

cat <<EOF |  tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF |  tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

#Add the Kubernetes apt repository and public signing key
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main' |  tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet kubectl and kubeadm


apt-get update
apt-get install -y kubelet=1.24.4-00 kubeadm=1.24.4-00 kubectl=1.24.4-00
apt-mark hold kubelet kubeadm kubectl

# Disable swap memory

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

#Enable and restart the services containerd and kubelet

systemctl enable kubelet
systemctl restart kubelet
#rm /etc/containerd/config.toml
containerd config default |  tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
systemctl daemon-reload

# Set hostname as private ipv4 dnsname from the instance metadata

hostnamectl set-hostname $(curl  "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")

#cluster_name = $1

# Create a kubeadm configuration file which will be used during init
cat <<EOF> /tmp/kubeconfigold.yaml
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
apiServer:
  extraArgs:
    cloud-provider: gce
clusterName: kubernetes
controlPlaneEndpoint: $(curl "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" -H "Metadata-Flavor: Google"):6443
controllerManager:
  extraArgs:
    cloud-provider: gce
    configure-cloud-routes: 'false'
kubernetesVersion: v1.24.4
networking:
  dnsDomain: cluster.local
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler:
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
nodeRegistration:
  name: '$(curl  "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")'
  kubeletExtraArgs:
    cloud-provider: gce
EOF

# controlplane endpoint and node registration name will come from the instance metadata. 


# Migrate kubeconfig to a version compatible with the current kubeadm version
kubeadm config migrate --old-config /tmp/kubeconfigold.yaml --new-config /tmp/kubeconfig.yaml
export HOME=/root
# Creates the kubernetes cluster using the config file
kubeadm init --config /tmp/kubeconfig.yaml

# Copy config file to .kube directory under the user's home directory 
mkdir -p ~/.kube
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

#Install calico CNI
wget -O /tmp/calico.yaml https://docs.projectcalico.org/manifests/calico.yaml
kubectl apply -f /tmp/calico.yaml

kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl taint nodes --all node-role.kubernetes.io/control-plane-


echo "######### Kubernetes Cluster Creation is Complete   #########"

echo "####### Verify using kubectl commands #########"
