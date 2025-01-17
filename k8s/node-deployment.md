# Setup on Alpine linux
After the end of this doc you will have a functioning k8s cluster deployed on the created nodes. It will use:
- **cilium** as CNI
- **nginx** as ingress controller

> **NOTE**: All commands are run on specified nodes, pay close attention to similar notes

## Prerequisites
- Installed Alpine
- At least 4x CPUs and 4GB RAM for control node
- At least 2x CPUs and 4GB RAM for worker nodes
- At least one control node and one worker
- Other prerequisites on nodes:
    - `curl`
    - node is using `chrony`

## Prepare repositories 
Add repositories that contain neccessary tools 

`/etc/apk/repositories`
```
# http://dl-cdn.alpinelinux.org/ mirror is just an example
http://dl-cdn.alpinelinux.org/alpine/v3.21/main
http://dl-cdn.alpinelinux.org/alpine/v3.21/community
http://dl-cdn.alpinelinux.org/alpine/edge/community
http://dl-cdn.alpinelinux.org/alpine/edge/testing
```


## Node configuration

### Add kernel module for networking stuff
> **NOTE**: Run on all nodes

```
# echo "br_netfilter" > /etc/modules-load.d/k8s.conf
# modprobe br_netfilter
# sysctl net.ipv4.ip_forward=1
# echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
```

### Kernel stuff
```
# echo "net.bridge.bridge-nf-call-iptables=1" >> /etc/sysctl.conf
# sysctl net.bridge.bridge-nf-call-iptables=1
```

### Installing required packages
```
# apk add cni-plugins
# apk add kubelet
# apk add kubeadm
# apk add kubectl
# apk add containerd
# apk add uuidgen
# apk add nfs-utils
```

### Turn off swap
Turn off swap
```
# swapoff
```

Edit `/etc/fstab` and remove any mentions of swap

### Fix prometheus errors
```
# mount --make-rshared /
# echo "#!/bin/sh" > /etc/local.d/sharemetrics.start
# echo "mount --make-rshared /" >> /etc/local.d/sharemetrics.start
# chmod +x /etc/local.d/sharemetrics.start
# rc-update add local
```

### Fix id error messages
```
# uuidgen > /etc/machine-id
```

### Add services and enable containerd
```
# rc-update add containerd
# rc-update add kubelet
# rc-service containerd start
```

### We can now create our cluster
> **NOTE**: Run only on control node

Create cluster using kubeadm and link admin config to the root home
```
# kubeadm init
# mkdir ~/.kube
# ln -s /etc/kubernetes/admin.conf /root/.kube/config
``` 


### After successful cluster creation join nodes to the cluster
> **NOTE**: Run only on control node
```
# kubeadm token create --print-join-command 
```
Copy the command outputed in previous step and run it on all worker nodes.

> **NOTE**: Run only on worker nodes

Example command from previous step
```
# kubeadm join 192.168.x.x:6443 --token kwsxcy.enai475hu23q8ye8 --discovery-token-ca-cert-hash sha256:614da47f...
```

### Installing Cilium
> **NOTE**: Run only on control node

Download cilium and make it available to the system 
```
# CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
# CLI_ARCH=amd64
# if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
# curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
# sha256sum -c cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
# tar x -f cilium-linux-${CLI_ARCH}.tar.gz
# cp cilium /usr/local/bin
```

Next step after successful installation is to install CNI Cilium to our cluster

```
cilium install --version 1.16.5
```

After the installation command completes, link CNI executables so k8s can find them
> **NOTE**: Run on all nodes
```
# ln -s /opt/cni/bin/cilium-cni  /usr/libexec/cni/cilium-cni
```
Now we need to wait for cilium installation to finish.
> **NOTE**: Run only on control node
```
cilium status --wait
```
Wait until `Cilium` reports `OK` status.
If that's the case you should now have a fully working simple k8s cluster.

## Setting up ingress
Now we need to setup ingress controller
> **NOTE**: Run only on control node
```
# wget https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0-beta.0/deploy/static/provider/baremetal/deploy.yaml
```
After downloading the manifest file find the service resources and change their type from: `type: ClusterIP` to `type: LoadBalancer`.

Example config as of time of writing...
```
... Omitted ...
  name: ingress-nginx-controller
  namespace: ingress-nginx
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.12.0-beta.0
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  ipFamilies:
  - IPv4
  ipFamilyPolicy: SingleStack
  ports:
  - appProtocol: http
    name: http
    port: 80
    protocol: TCP
    targetPort: http
  - appProtocol: https
    name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  type: ClusterIP -> LoadBalancer
---
apiVersion: v1
kind: Service
... Omitted ...
```

After changing the resource types we need to prepare our load balancer.

## Setup load balancer MetalLB
If you’re using kube-proxy in IPVS mode, since Kubernetes v1.14.2 you have to enable strict ARP mode.
> **NOTE**: Run only on control node
```
# kubectl edit configmap -n kube-system kube-proxy
```
and set:
```
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
ipvs:
  strictARP: true
```
Install CRD of MetalLB
```
# kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```
Create IP Address pool for load balancer to assing `ipaddresspool.yaml`. Addresses must be unique, for example you can not use the already taken addresses by nodes.
```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: my-lb-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.10-192.168.1.20
```
Create L2 Advertisement `l2advertisements.yaml`
```
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: my-l2-advertisement
  namespace: metallb-system
```
Apply the new resources to the cluster
```
# kubectl apply -f ipaddresspool.yaml
# kubectl apply -f l2advertisement.yaml
```
We should now have a functioning load balancer.

Last step is to deploy ingress controller from previous steps.
```
# kubectl apply -f deploy.yaml
```

Wait for everything to deploy.

As a test you can quickly create any service of type `LoadBalancer` and it should get assinged IP address from the pool you specified.
In the previous step we changed nginx service to type `LoadBalancer`. Go ahead and check if the service got assinged External IP from load balancer.
