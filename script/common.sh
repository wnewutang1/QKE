#!/usr/bin/env bash
SCRIPTPATH=$( cd $(dirname $0) ; pwd -P )
K8S_HOME=$(dirname "${SCRIPTPATH}")
KUBEADM_CONFIG_PATH="/data/kubernetes/kubeadm-config.yaml"
KUBECONFIG="/etc/kubernetes/admin.conf"
NODE_INIT_LOCK="/data/kubernetes/node-init.lock"
CLIENT_INIT_LOCK="/data/kubernetes/client-init.lock"
ORIGINAL_DIR=("/var/lib/docker" "/root/.docker"
"/var/lib/etcd" "/var/lib/kubelet" 
"/etc/kubernetes" "/root/.kube")
DATA_DIR=("/data/var/lib/docker" "/data/root/.docker"
"/data/var/lib/etcd" "/data/var/lib/kubelet"
"/data/kubernetes" "/data/root/.kube")
PATH=$PATH:/usr/local/bin
source "/data/env.sh"
source "${K8S_HOME}/version"

#set -o errexit
set -o nounset
set -o pipefail

function retry {
  local n=1
  local max=20
  local delay=6
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        fail "The command has failed after $n attempts."
      fi
    }
  done
}

function get_node_status(){
    local status=$(kubectl get nodes/${HOST_INSTANCE_ID} --kubeconfig /etc/kubernetes/kubelet.conf -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    echo ${status}
}

function drain_node(){
    kubectl drain  --kubeconfig /etc/kubernetes/admin.conf  --delete-local-data=true --ignore-daemonsets=true --force $1 
    return $?
}

function wait_etcd(){
    is_systemd_active etcd
}

function is_systemd_active(){
    retry systemctl is-active $1 > /dev/null 2>&1
}

# Link dir from data volume
function ensure_dir(){
    for i in "${!ORIGINAL_DIR[@]}"
    do
        if [ -d ${ORIGINAL_DIR[$i]} ] && [ ! -L ${ORIGINAL_DIR[$i]} ]
        then
            rm -rf ${ORIGINAL_DIR[$i]}
        fi
        ln -sfT ${DATA_DIR[$i]} ${ORIGINAL_DIR[$i]}
    done
}

function make_dir(){
    mkdir -p /data/var/lib
    mkdir -p /data/root
    mkdir -p /root/.kube
    mkdir -p /etc/kubernetes/pki
}

# Copy dir into data volume
function link_dir(){
    make_dir
    for i in "${!ORIGINAL_DIR[@]}"
    do
        if [ -d ${ORIGINAL_DIR[$i]} ] && [ ! -L ${ORIGINAL_DIR[$i]} ]
        then
            mv ${ORIGINAL_DIR[$i]} $(dirname ${DATA_DIR[$i]})
            ln -sfT ${DATA_DIR[$i]} ${ORIGINAL_DIR[$i]}
        fi
    done
}

function upgrade_docker(){
    #clear old aufs
    rm -rf /data/var/lib/docker/aufs
    rm -rf /data/var/lib/docker/image
    #copy overlays2
    mv /var/lib/docker/image /data/var/lib/docker/
    mv /var/lib/docker/overlay2 /data/var/lib/docker/
    rm -rf /var/lib/docker
    ln -s /data/var/lib/docker /var/lib/docker
    ln -s /data/var/lib/kubelet /var/lib/kubelet
    return 0
}

function wait_apiserver(){
    while ! curl --output /dev/null --silent --fail http://localhost:8080/healthz;
    do
        echo "waiting k8s api server" && sleep 2
    done;
}

function docker_stop_rm_all () {
    for i in `docker ps -q`
    do
        docker stop $i;
    done
    for i in `docker ps -aq`
    do
        docker rm -f $i;
    done
}

function docker_stop () {
  retry systemctl stop docker
}

function set_password(){
    echo "root:k8s" |chpasswd
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart ssh
}

function install_network_plugin(){
    case "${NETWORK_PLUGIN}" in
    "calico")
        kubectl apply -f /opt/kubernetes/k8s/addons/calico/calico-rbac.yaml
        kubectl apply -f /opt/kubernetes/k8s/addons/calico/calico-deploy.yaml
        ;;
    "flannel")
        kubectl apply -f /opt/kubernetes/k8s/addons/flannel/flannel-deploy.yaml
        ;;
    *)
        echo "Invalid network plugin" ${NETWORK_PLUGIN} >&2
        exit -1
        ;;
    esac
}

function install_kube_proxy(){
    if [ "${ENV_MASTER_COUNT}" == "3" ]
    then
        lb_ip=`cat /etc/kubernetes/loadbalancer_ip`
        replace_kv /opt/kubernetes/k8s/addons/kube-proxy/kube-proxy-cm.yaml server SHOULD_BE_REPLACED $(echo ${lb_ip})
    fi
    kubectl apply -f /opt/kubernetes/k8s/addons/kube-proxy/kube-proxy-cm.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/kube-proxy/rbac.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/kube-proxy/kube-proxy-ds.yaml
}

function join_node(){
    if [ -f "${NODE_INIT_LOCK}" ]; then
        echo "node has joined."
        return
    fi

    local init_token=`cat /data/kubernetes/init_token.metad`
    while [ -z "${init_token}" ]
    do
        echo "sleep for wait init_token for 2 second"
        sleep 2
        init_token=`cat /data/kubernetes/init_token.metad`
    done

    echo "Token: ${init_token}"
    retry ${init_token}

    touch ${NODE_INIT_LOCK}
}

function install_csi(){
    kubectl create configmap csi-qingcloud --from-file=config.yaml=/etc/qingcloud/client.yaml --namespace=kube-system
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-secret.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-controller-rbac.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-node-rbac.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-controller-sts.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-node-ds.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/qingcloud-csi/csi-sc.yaml
}

function install_coredns(){
    kubeadm alpha phase addon coredns --config ${KUBEADM_CONFIG_PATH}
    kubectl apply -f /opt/kubernetes/k8s/addons/coredns/coredns-rbac.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/coredns/coredns-deploy.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/coredns/coredns-cm.yaml
}

function install_tiller(){
    kubectl apply -f /opt/kubernetes/k8s/addons/tiller/tiller-sa.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/tiller/tiller-deploy.yaml
    kubectl apply -f /opt/kubernetes/k8s/addons/tiller/tiller-svc.yaml
}

function install_cloud_controller_manager(){
    cp /opt/kubernetes/k8s/addons/cloud-controller-manager/cloud-controller-manager.yaml /etc/kubernetes/manifests
}

function docker_login(){
    if [ ! -z "${ENV_PRIVATE_REGISTRY}" ]
    then
        if [ ! -z "${ENV_DOCKERHUB_USERNAME}" ] && [ ! -z "${ENV_DOCKERHUB_PASSWORD}" ]
        then
            retry docker login ${ENV_PRIVATE_REGISTRY} -u ${ENV_DOCKERHUB_USERNAME} -p ${ENV_DOCKERHUB_PASSWORD}
        fi
    else
        if [ ! -z "${ENV_DOCKERHUB_USERNAME}" ] && [ ! -z "${ENV_DOCKERHUB_PASSWORD}" ]
        then
            retry docker login dockerhub.qingcloud.com -u ${ENV_DOCKERHUB_USERNAME} -p ${ENV_DOCKERHUB_PASSWORD}
        fi
    fi
}

function replace_kv(){
    filepath=$1
    key=$2
    symbolvalue=$3
    actualvalue=$4
    if [ -f $1 ]
    then
        sed "/${key}/s@${symbolvalue}@${actualvalue}@g" -i ${filepath}
    fi
}

function makeup_kubesphere_values(){
    scp root@master1:/etc/kubernetes/pki/* /etc/kubernetes/pki
    local kubernetes_token=$(kubectl -n kubesphere-system get secrets $(kubectl -n kubesphere-system get sa kubesphere -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.token}' | base64 -d)
    replace_kv /opt/kubesphere/kubesphere/values.yaml kubernetes_token SHOULD_BE_REPLACED ${kubernetes_token}
    local kubernetes_ca_crt=$(cat /etc/kubernetes/pki/ca.crt | base64 | tr -d "\n")
    replace_kv /opt/kubesphere/kubesphere/values.yaml kubernetes_ca_crt SHOULD_BE_REPLACED ${kubernetes_ca_crt}
    local kubernetes_ca_key=$(cat /etc/kubernetes/pki/ca.key | base64 | tr -d "\n")
    replace_kv /opt/kubesphere/kubesphere/values.yaml kubernetes_ca_key SHOULD_BE_REPLACED ${kubernetes_ca_key}
    local kubernetes_front_proxy_client_crt=$(cat /etc/kubernetes/pki/front-proxy-client.crt | base64 | tr -d "\n")
    replace_kv /opt/kubesphere/kubesphere/values.yaml kubernetes_front_proxy_client_crt SHOULD_BE_REPLACED ${kubernetes_front_proxy_client_crt}
    local kubernetes_front_proxy_client_key=$(cat /etc/kubernetes/pki/front-proxy-client.key | base64 | tr -d "\n")
    replace_kv /opt/kubesphere/kubesphere/values.yaml kubernetes_front_proxy_client_key SHOULD_BE_REPLACED ${kubernetes_front_proxy_client_key}
}

function install_kubesphere(){
    if [ -f "${CLIENT_INIT_LOCK}" ]; then
        echo "client has installed KubeSphere"
        return
    fi
    helm upgrade --install ks-openpitrix  /opt/kubesphere/openpitrix/  --namespace openpitrix-system
    helm upgrade --install ks-jenkins /opt/kubesphere/jenkins -f /opt/kubesphere/custom-values-jenkins.yaml --namespace kubesphere-devops-system
    helm upgrade --install ks-monitoring  /opt/kubesphere/ks-monitoring/ --namespace kubesphere-monitoring-system
    helm upgrade --install metrics-server  /opt/kubesphere/metrics-server/ --namespace kube-system
    kubectl  apply  -f  /opt/kubesphere/init.yaml
    makeup_kubesphere_values
    helm upgrade --install kubesphere  /opt/kubesphere/kubesphere/  --namespace kubesphere-system
    kubectl label ns $(kubectl get ns | awk '{if(NR>1) {print $1}}') kubesphere.io/workspace=system-workspace
    kubectl annotate namespaces $(kubectl get ns | awk '{if(NR>1) {print $1}}') creator=admin
    # install logging
    helm upgrade --install elasticsearch-logging /opt/kubesphere/elasticsearch/  --namespace kubesphere-logging-system
    helm upgrade --install elasticsearch-logging-curator /opt/kubesphere/elasticsearch-curator/  --namespace kubesphere-logging-system
    helm upgrade --install elasticsearch-logging-kibana /opt/kubesphere/kibana/  --namespace kubesphere-logging-system
    helm upgrade --install elasticsearch-logging-fluentbit /opt/kubesphere/fluent-bit/  --namespace kubesphere-logging-system
    kubectl apply -f /opt/kubernetes/k8s/addons/logging/es-logging-cm.yaml
    touch ${CLIENT_INIT_LOCK}
}

function get_loadbalancer_ip(){
    lb_ip=`cat /etc/kubernetes/loadbalancer_ip`
    echo "${lb_ip}"
}

function replace_kubeadm_config_lb_ip(){
    lb_ip=`cat /etc/kubernetes/loadbalancer_ip`
    replace_kv /etc/kubernetes/kubeadm-config.yaml controlPlaneEndpoint SHOULD_BE_REPLACED $(echo ${lb_ip})
}

function replace_hosts_lb_ip(){
    lb_ip=`cat /etc/kubernetes/loadbalancer_ip`
    replace_kv /etc/hosts loadbalancer SHOULD_BE_REPLACED $(echo ${lb_ip})
}