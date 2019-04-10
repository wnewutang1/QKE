# 构建虚拟机镜像

- 基于 Ubuntu 16.04.4 构建，切换到 root 用户

- 下载代码仓库
```bash
apt-get install -y git
git clone https://github.com/QingCloudAppcenter/kubesphere.git /opt/kubesphere
cd /opt/kubesphere
```

- 下载所需内容

```bash
image/build-base.sh
```

- 拷贝 confd 文件

```
cp -r /opt/kubernetes/confd/conf.d /etc/confd/
cp -r /opt/kubernetes/confd/templates /etc/confd/
```

- 修改 Kubelet 启动 service 文件

添加参数，为健康检查用。待 Kubeadm 能够正常添加参数，此步可删去。

```
vim /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --anonymous-auth=true --authorization-mode=AlwaysAllow"
```