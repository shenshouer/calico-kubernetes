mkdir -p /opt/bin/ && mkdir -p /opt/kubernetes/manifests/ && cd /opt/bin/ && cp -rf /vagrant/cloud-config/* ./ && chmod a+x * 
mkdir -p /opt/cni/bin && cd /opt/cni/bin && mv /opt/bin/calico ./ && mv /opt/bin/calico-ipam ./

/opt/bin/make-ca-cert.sh 172.18.18.101 IP:172.18.18.101,IP:10.100.0.1,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local
chmod 664 /srv/kubernetes/*
