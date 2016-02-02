#kubernetes与calico整合

##说明
以前的kubernetes集群都是基于flannel搭建的，但应用系统所用的容器之间都能互访，存在一定的安全性，因calico在网络方面可支持策略，本文档为基于calico搭建kubernetes集群的记录

所有文件已经下载完成，并放置与我的github上 <a href="https://github.com/shenshouer/calico-kubernetes">calico-kubernetes</a>。

##环境准备
* 宿主机系统CentOS 7.1 64bit
* virtualbox 5.0.14
* vagrant 1.8.1
* CoreOS alpha 928.0.0
* kubernetes v1.1.7
* calicoctl v0.15.0
* calico v1.0
* calico-ipam v1.0

##安装
相关配置文件及组件下载完成后目录结构如下所示：

```
➜  coreos  tree
.
├── cloud-config
│   ├── calico
│   ├── calicoctl
│   ├── calico-ipam
│   ├── easy-rsa.tar.gz
│   ├── key.sh
│   ├── kube-apiserver
│   ├── kube-controller-manager
│   ├── kubectl
│   ├── kubelet
│   ├── kube-proxy
│   ├── kube-scheduler
│   ├── make-ca-cert.sh
│   ├── master-config.yaml
│   ├── master-config.yaml.tmpl
│   ├── network-environment
│   ├── node-config.yaml_calico-02
│   ├── node-config.yaml_calico-03
│   ├── node-config.yaml.tmpl
│   └── setup-network-environment
├── manifests
│   ├── busybox.yaml
│   ├── kube-ui-rc.yaml
│   ├── kube-ui-svc.yaml
│   └── skydns.yaml
├── synced_folders.yaml
└── Vagrantfile
```
### 必要二进制工具下载
```
# 创建目录
mkdir cloud-config && cd cloud-config
## 下载calico相关组件
wget https://github.com/projectcalico/calico-containers/releases/download/v0.15.0/calicoctl
wget https://github.com/projectcalico/calico-cni/releases/download/v1.0.0/calico
wget https://github.com/projectcalico/calico-cni/releases/download/v1.0.0/calico-ipam

## 下载kubernetes相关组件
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kubectl
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kubelet
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kube-proxy
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kube-apiserver
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kube-controller-manager
wget http://storage.googleapis.com/kubernetes-release/release/v1.1.7/bin/linux/amd64/kube-scheduler

## 下载环境设置工具
wget https://github.com/kelseyhightower/setup-network-environment/releases/download/1.0.1/setup-network-environment

## 下载证书制作工具（也可以使用CoreOS系统自带的，本文档中不包含后续再更新）
wget https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz
```

### cloud-init配置文件模板
目录中`master-config.yaml`、`node-config.yaml_calico-02`、`node-config.yaml_calico-03`为启动集群时根据`.tmpl`文件自动生成的配置文件

####master cloud-init模板
~/cloud-config/master-config.yaml.tmpl 内容如下：

```
#cloud-config
---
write_files:
  # Network config file for the Calico CNI plugin.
  - path: /etc/cni/net.d/10-calico.conf
    owner: root
    permissions: 0755
    content: |
      {
          "name": "calico-k8s-network",
          "type": "calico",
          "etcd_authority": "172.18.18.101:2379",
          "log_level": "info",
          "ipam": {
              "type": "calico-ipam"
          }
      }

  # Kubeconfig file.
  - path: /etc/kubernetes/worker-kubeconfig.yaml
    owner: root
    permissions: 0755
    content: |
      apiVersion: v1
      kind: Config
      clusters:
      - name: local
        cluster:
          server: http://172.18.18.101:8080
      users:
      - name: kubelet
      contexts:
      - context:
          cluster: local
          user: kubelet
        name: kubelet-context
      current-context: kubelet-context


hostname: __HOSTNAMT__
coreos:
  update:
    reboot-strategy: off
  etcd2:
    name: "etcdserver"
    listen-client-urls: http://0.0.0.0:2379
    advertise-client-urls: http://$private_ipv4:2379
    initial-cluster: etcdserver=http://$private_ipv4:2380
    initial-advertise-peer-urls: http://$private_ipv4:2380
    listen-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    listen-peer-urls: http://0.0.0.0:2380
  fleet:
    metadata: "role=master"
    etcd_servers: "http://localhost:2379"
  units:
    - name: etcd2.service
      command: start
    - name: fleet.service
      command: start
    - name: setup-network-environment.service
      command: start
      content: |
        [Unit]
        Description=Setup Network Environment
        Documentation=https://github.com/kelseyhightower/setup-network-environment
        Requires=network-online.target
        After=network-online.target
        [Service]
        ExecStartPre=-/usr/bin/chmod +x /opt/bin/setup-network-environment
        ExecStart=/opt/bin/setup-network-environment
        RemainAfterExit=yes
        Type=oneshot
        [Install]
        WantedBy=multi-user.target
    - name: kube-apiserver.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes API Server
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=etcd2.service
        After=etcd2.service
        [Service]
        ExecStart=/opt/bin/kube-apiserver \
        --allow-privileged=true \
        --etcd-servers=http://$private_ipv4:2379 \
        --admission-control=NamespaceLifecycle,NamespaceExists,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota \
        --insecure-bind-address=0.0.0.0 \
        --advertise-address=$private_ipv4 \
        --service-account-key-file=/srv/kubernetes/kubecfg.key \
        --tls-cert-file=/srv/kubernetes/server.cert \
        --tls-private-key-file=/srv/kubernetes/server.key \
        --service-cluster-ip-range=10.100.0.0/16 \
        --client-ca-file=/srv/kubernetes/ca.crt \
        --kubelet-https=true \
        --secure-port=443 \
        --runtime-config=extensions/v1beta1/daemonsets=true,extensions/v1beta1/deployments=true,extensions/v1beta1/ingress=true \
        --logtostderr=true
        Restart=always
        RestartSec=10
        [Install]
        WantedBy=multi-user.target
    - name: kube-controller-manager.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Controller Manager
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kube-apiserver.service
        After=kube-apiserver.service
        [Service]
        ExecStart=/opt/bin/kube-controller-manager \
        --master=$private_ipv4:8080 \
        --service_account_private_key_file=/srv/kubernetes/kubecfg.key \
        --root-ca-file=/srv/kubernetes/ca.crt \
        --logtostderr=true
        Restart=always
        RestartSec=10
        [Install]
        WantedBy=multi-user.target
    - name: kube-scheduler.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Scheduler
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kube-apiserver.service
        After=kube-apiserver.service
        [Service]
        ExecStart=/opt/bin/kube-scheduler --master=$private_ipv4:8080 --logtostderr=true
        Restart=always
        RestartSec=10
        [Install]
        WantedBy=multi-user.target
    - name: calico-node.service
      command: start
      content: |
        [Unit]
        Description=calicoctl node
        After=docker.service
        Requires=docker.service

        [Service]
        #EnvironmentFile=/etc/network-environment
        User=root
        Environment="ETCD_AUTHORITY=127.0.0.1:2379"
        PermissionsStartOnly=true
        #ExecStartPre=/opt/bin/calicoctl pool add 192.168.0.0/16 --ipip --nat-outgoing
        ExecStart=/opt/bin/calicoctl node --ip=$private_ipv4 --detach=false
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=multi-user.target

    - name: kubelet.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Kubelet
        Documentation=https://github.com/kubernetes/kubernetes
        After=docker.service
        Requires=docker.service

        [Service]
        ExecStart=/opt/bin/kubelet \
        --register-node=true \
        --pod-infra-container-image="shenshouer/pause:0.8.0" \
        --allow-privileged=true \
        --config=/opt/kubernetes/manifests \
        --cluster-dns=10.100.0.10 \
        --hostname-override=$private_ipv4 \
        --api-servers=http://localhost:8080 \
        --cluster-domain=cluster.local \
        --network-plugin-dir=/etc/cni/net.d \
        --network-plugin=cni \
        --logtostderr=true
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=multi-user.target

    - name: kube-proxy.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Proxy
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kubelet.service
        After=kubelet.service
        [Service]
        ExecStart=/opt/bin/kube-proxy \
        --master=http://$private_ipv4:8080 \
        --proxy-mode=iptables \
        --logtostderr=true
        Restart=always
        RestartSec=10
        [Install]
        WantedBy=multi-user.target
```

~/cloud-config/node-config.yaml.tmpl 内容如下：

```
#cloud-config
---
write_files:
  # Network config file for the Calico CNI plugin.
  - path: /etc/cni/net.d/10-calico.conf
    owner: root
    permissions: 0755
    content: |
      {
          "name": "calico-k8s-network",
          "type": "calico",
          "etcd_authority": "172.18.18.101:2379",
          "log_level": "info",
          "ipam": {
              "type": "calico-ipam"
          }
      }

  # Kubeconfig file.
  - path: /etc/kubernetes/worker-kubeconfig.yaml
    owner: root
    permissions: 0755
    content: |
      apiVersion: v1
      kind: Config
      clusters:
      - name: local
        cluster:
          server: http://172.18.18.101:8080
      users:
      - name: kubelet
      contexts:
      - context:
          cluster: local
          user: kubelet
        name: kubelet-context
      current-context: kubelet-context

hostname: __HOSTNAMT__
coreos:
  etcd2:
    proxy: on
    listen-client-urls: http://localhost:2379
    initial-cluster: etcdserver=http://172.18.18.101:2380
  fleet:
    metadata: "role=node"
    etcd_servers: "http://localhost:2379"
  update:
    reboot-strategy: off
  units:
    - name: etcd2.service
      command: start
    - name: fleet.service
      command: start
    - name: setup-network-environment.service
      command: start
      content: |
        [Unit]
        Description=Setup Network Environment
        Documentation=https://github.com/kelseyhightower/setup-network-environment
        Requires=network-online.target
        After=network-online.target
        [Service]
        ExecStartPre=-/usr/bin/chmod +x /opt/bin/setup-network-environment
        ExecStart=/opt/bin/setup-network-environment
        RemainAfterExit=yes
        Type=oneshot
        [Install]
        WantedBy=multi-user.target
    - name: calico-node.service
      command: start
      content: |
        [Unit]
        Description=calicoctl node
        After=docker.service
        Requires=docker.service

        [Service]
        #EnvironmentFile=/etc/network-environment
        User=root
        Environment=ETCD_AUTHORITY=172.18.18.101:2379
        PermissionsStartOnly=true
        ExecStart=/opt/bin/calicoctl node --ip=$private_ipv4 --detach=false
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=multi-user.target

    - name: kubelet.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Kubelet
        Documentation=https://github.com/kubernetes/kubernetes
        After=docker.service
        Requires=docker.service

        [Service]
        ExecStart=/opt/bin/kubelet \
        --address=0.0.0.0 \
        --allow-privileged=true \
        --cluster-dns=10.100.0.10 \
        --cluster-domain=cluster.local \
        --config=/opt/kubernetes/manifests \
        --hostname-override=$private_ipv4 \
        --api-servers=http://172.18.18.101:8080 \
        --pod-infra-container-image="shenshouer/pause:0.8.0" \
        --network-plugin-dir=/etc/cni/net.d \
        --network-plugin=cni \
        --logtostderr=true
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=multi-user.target

    - name: kube-proxy.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Proxy
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kubelet.service
        After=kubelet.service
        [Service]
        ExecStart=/opt/bin/kube-proxy \
        --master=http://172.18.18.101:8080 \
        --proxy-mode=iptables \
        --logtostderr=true
        Restart=always
        RestartSec=10
        [Install]
        WantedBy=multi-user.target
```

### 集群附件组件
文件夹`manifests`中为测试工具以及DNS、kube-ui等附件组件配置文件

当启动集群时，将自动复制到master节点的home目录中

###Vagrantfile配置

```
require 'fileutils'
require 'yaml'

# Size of the cluster created by Vagrant
num_instances=3

# Read YAML file with mountpoint details
MOUNT_POINTS = YAML::load_file('synced_folders.yaml')

module OS
  def OS.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def OS.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def OS.unix?
    !OS.windows?
  end

  def OS.linux?
    OS.unix? and not OS.mac?
  end
end

# Change basename of the VM
instance_name_prefix="calico"

Vagrant.configure("2") do |config|
  # always use Vagrants insecure key
  config.ssh.insert_key = false
  # 指定创建集群vm所需的box
  config.vm.box = "coreos-alpha-928.0.0"

  config.vm.provider :virtualbox do |v|
    # On VirtualBox, we don't have guest additions or a functional vboxsf
    # in CoreOS, so tell Vagrant that so it can be smarter.
    v.check_guest_additions = false
    v.memory = 2048
    v.cpus = 2
    v.functional_vboxsf     = false
  end

  # Set up each box
  (1..num_instances).each do |i|
    vm_name = "%s-%02d" % [instance_name_prefix, i]
    config.vm.define vm_name do |host|
      host.vm.hostname = vm_name
	host.vm.synced_folder ".", "/vagrant", disabled: true
	# 挂载当前目录到虚拟机中的/vagrant目录，自动化部署
	begin
	  MOUNT_POINTS.each do |mount|
	    mount_options = ""
	    disabled = false
	    nfs =  true
	    if mount['mount_options']
		mount_options = mount['mount_options']
	    end
	    if mount['disabled']
		disabled = mount['disabled']
	    end
	    if mount['nfs']
		nfs = mount['nfs']
	    end
	    if File.exist?(File.expand_path("#{mount['source']}"))
		if mount['destination']
		  host.vm.synced_folder "#{mount['source']}", "#{mount['destination']}",
		    id: "#{mount['name']}",
		    disabled: disabled,
		    mount_options: ["#{mount_options}"],
		    nfs: nfs
		end
	    end
	  end
	rescue
	end
	# 指定虚拟机的ip地址范围
      ip = "172.18.18.#{i+100}"
      host.vm.network :private_network, ip: ip

      host.vm.provision :shell, :inline => "/usr/bin/timedatectl set-timezone Asia/Shanghai ", :privileged => true
      # 自动将对应二进制文件复制到对应目录中
      host.vm.provision :shell, :inline => "chmod +x /vagrant/cloud-config/key.sh && /vagrant/cloud-config/key.sh ", :privileged => true
      #host.vm.provision :shell, :inline => "cp /vagrant/cloud-config/network-environment /etc/network-environment", :privileged => true
      # docker pull 相应必要镜像文件
      host.vm.provision :docker, images: ["busybox:latest", "shenshouer/pause:0.8.0", "calico/node:v0.15.0"]
      sedInplaceArg = OS.mac? ? " ''" : ""
      if i == 1
        # Configure the master.
        system "cp cloud-config/master-config.yaml.tmpl cloud-config/master-config.yaml"
        system "sed -e 's|__HOSTNAMT__|#{vm_name}|g' -i#{sedInplaceArg} ./cloud-config/master-config.yaml"
        host.vm.provision :file, :source => "./manifests/skydns.yaml", :destination => "/home/core/skydns.yaml"
        host.vm.provision :file, :source => "./manifests/busybox.yaml", :destination => "/home/core/busybox.yaml"
        host.vm.provision :file, :source => "./cloud-config/master-config.yaml", :destination => "/tmp/vagrantfile-user-data"
        host.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
      else
        # Configure a node.
        system "cp cloud-config/node-config.yaml.tmpl cloud-config/node-config.yaml_#{vm_name}"
        system "sed -e 's|__HOSTNAMT__|#{vm_name}|g' -i#{sedInplaceArg} ./cloud-config/node-config.yaml_#{vm_name}"
        host.vm.provision :file, :source => "./cloud-config/node-config.yaml_#{vm_name}", :destination => "/tmp/vagrantfile-user-data"
        host.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
      end
    end
  end
end
```

##部署附件组件

在Vagrantfile所在目录中执行`vagrant up`,启动过程因挂载宿主机目录到虚拟机会要求输入宿主机密码.

启动过程中会使用vm中的docker pull必要的镜像文件，等待自动化部署完成

##部署 集群附加组件

在当前目录中执行`vagrant ssh calico-01`进入到master主机中:

```
core@calico-01 ~ $ ls
busybox.yaml  kube-ui-rc.yaml  kube-ui-svc.yaml  skydns.yaml

# 查看节点情况
core@calico-01 ~ $ kubectl get node
NAME            LABELS                                 STATUS    AGE
172.18.18.101   kubernetes.io/hostname=172.18.18.101   Ready     3h
172.18.18.102   kubernetes.io/hostname=172.18.18.102   Ready     3h
172.18.18.103   kubernetes.io/hostname=172.18.18.103   Ready     3h

# 创建kube-system namespace，部署skydns rc,部署skydns svc：
kubectl create -f skydns.yaml

# 部署kube-ui
kubectl create -f kube-ui-rc.yaml
kubectl create -f kube-ui-svc.yaml


# 查看执行结果

core@calico-01 ~ $ kubectl get po -o wide --namespace=kube-system
NAME                READY     STATUS    RESTARTS   AGE       NODE
kube-dns-v9-qd8i3   4/4       Running   0          3h        172.18.18.103
kube-ui-v5-8spea    1/1       Running   0          3h        172.18.18.102

# 验证DNS
# 部署busybox工具
kubectl create -f busybox.yaml

core@calico-01 ~ $ kubectl get po -o wide
NAME      READY     STATUS    RESTARTS   AGE       NODE
busybox   1/1       Running   3          3h        172.18.18.101

# 验证DNS
core@calico-01 ~ $ kubectl exec busybox -- nslookup kubernetes
Server:    10.100.0.10
Address 1: 10.100.0.10

Name:      kubernetes
Address 1: 10.100.0.1

# 查看calico状态
core@calico-01 ~ $ calicoctl status
calico-node container is running. Status: Up 3 hours
Running felix version 1.3.0rc6

IPv4 BGP status
IP: 172.18.18.101    AS Number: 64511 (inherited)
+---------------+-------------------+-------+----------+-------------+
|  Peer address |     Peer type     | State |  Since   |     Info    |
+---------------+-------------------+-------+----------+-------------+
| 172.18.18.102 | node-to-node mesh |   up  | 03:57:16 | Established |
| 172.18.18.103 | node-to-node mesh |   up  | 03:59:36 | Established |
+---------------+-------------------+-------+----------+-------------+

IPv6 BGP status
No IPv6 address configured.

# 查看busybox容器地址分配，为192.168.0.0
core@calico-01 ~ $ kubectl describe po busybox
Name:				busybox
Namespace:			default
Image(s):			busybox
Node:				172.18.18.101/172.18.18.101
Start Time:			Tue, 02 Feb 2016 12:02:36 +0800
Labels:				<none>
Status:				Running
Reason:
Message:
IP:				192.168.0.0
Replication Controllers:	<none>
Containers:
  busybox:
    Container ID:		docker://2ffad63169095e31816bd10e45270e2d6add39480f61a5370ba76d7e4c5dd86b
    Image:			busybox
    Image ID:			docker://b175bcb790231169e232739bd2172bded9669c25104a9b723999c5f366ed7543
    State:			Running
      Started:			Tue, 02 Feb 2016 15:03:03 +0800
    Last Termination State:	Terminated
      Reason:			Error
      Exit Code:		0
      Started:			Tue, 02 Feb 2016 14:02:52 +0800
      Finished:			Tue, 02 Feb 2016 15:02:52 +0800
    Ready:			True
    Restart Count:		3
    Environment Variables:
Conditions:
  Type		Status
  Ready 	True
Volumes:
  default-token-9u1ub:
    Type:	Secret (a secret that should populate this volume)
    SecretName:	default-token-9u1ub
Events:
  FirstSeen	LastSeen	Count	From			SubobjectPath			Reason	Message
  ─────────	────────	─────	────			─────────────			──────	───────
  3h		37m		4	{kubelet 172.18.18.101}	spec.containers{busybox}	Pulled	Container image "busybox" already present on machine
  37m		37m		1	{kubelet 172.18.18.101}	spec.containers{busybox}	Created	Created with docker id 2ffad6316909
  37m		37m		1	{kubelet 172.18.18.101}	spec.containers{busybox}	Started	Started with docker id 2ffad6316909
  
# 查看集群信息中的对外服务
core@calico-01 ~ $ kubectl cluster-info
Kubernetes master is running at http://localhost:8080
KubeDNS is running at http://localhost:8080/api/v1/proxy/namespaces/kube-system/services/kube-dns
KubeUI is running at http://localhost:8080/api/v1/proxy/namespaces/kube-system/services/kube-ui
```

在宿主机上浏览器打开http://172.18.18.101:8080/api/v1/proxy/namespaces/kube-system/services/kube-ui即可看到集群信息。
部署完成，验证也ok，开心地玩耍吧。
