#!/bin/bash +x
set -e
usage="usage: google_cloud_setup.sh <command>

commands:
    get-credential          Get google credentials
    create-cluster          Create a new cluster
    install-chart           Install the Helm chart
    upgrade-chart           Upgrade (Redeploy) the Helm chart
    uninstall-chart         Delete the Helm release/chart
    delete-cluster          Delete cluster and perform a cleanup
    help                    Show this help

environment variables:
    NUM_NODES               Number of nodes to create in the cluster, default: 2
    PREFIX                  Prefix to add to Cluster and Pod names, default: 'rel'
    MYVALUES_FILE           Path to custom helm chart values file, default: 'myvalues.yaml'

    MACHINE_ZONE            Google Cloud zone, default: 'europe-west1-b'
    MACHINE_TYPE            Google Cloud instance type, default: 'n1-standard-4'
    CLUSTER_VERSION         Kubernetes version, default: 1.10
    DISK_TYPE               Cloud storage type, default: 'pd-standard'
    INSTANCE_DISK_SIZE      Google instance size (GB), default: 50
    NUM_CPUS                Number of CPUs per instance, default: 1
    NUM_GPUS                Number of GPUs per instance, 0 to not use GPU instances, default: 0
    GPU_TYPE                The type of GPU to use, default: 'nvidia-tesla-p100'

    "


NUM_NODES=${NUM_NODES:-2}
PREFIX=${PREFIX:-rel}
RELEASE_NAME=${PREFIX}-${NUM_NODES}
CLUSTER_NAME=${PREFIX}-${NUM_NODES}

MACHINE_ZONE=${MACHINE_ZONE:-europe-west1-b}
MYVALUES_FILE=${MYVALUES_FILE:-config.yaml}

MACHINE_TYPE=${MACHINE_TYPE:-n1-standard-4}
CLUSTER_VERSION=${CLUSTER_VERSION:-1.11.7-gke.6}
INSTANCE_DISK_SIZE=${INSTANCE_DISK_SIZE:-50}
DISK_TYPE=${DISK_TYPE:-pd-standard}
NUM_CPUS=${NUM_CPUS:-1}
NUM_GPUS=${NUM_GPUS:-0}
GPU_TYPE=${GPU_TYPE:-nvidia-tesla-p100}

MACHINE_ARCHITECTURE=`uname -m`

if [ ! -f $MYVALUES_FILE ]; then
    echo "Custom Helm values yaml ($MYVALUES_FILE) not found"
    exit 1
fi

function gcloud::check_installed(){
    if ! [ -x "$(command -v gcloud)" ]; then
        echo "Installing Google Cloud SDK"

        if [ ${MACHINE_ARCHITECTURE} == 'x86_64' ]; then
            curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-233.0.0-linux-x86_64.tar.gz | tar -xz
        else
            curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-233.0.0-linux-x86.tar.gz | tar -xz
        fi

        ./google-cloud-sdk/install.sh
        ./google-cloud-sdk/bin/gcloud init
    fi
}

function helm::check_installed(){
    if ! [ -x "$(command -v helm)" ]; then
        echo "Installing Helm"

        # curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
        source <(curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get)
    fi
}

function gcloud::get_credential(){
    gcloud::check_installed
    gcloud container clusters get-credentials --zone ${MACHINE_ZONE} ${CLUSTER_NAME}
}

function kube::worker::hostnames(){
    # Get a sequence of names; if you want an array, use additional parentheses ($(kube::worker::hostnames))
    kubectl get pods | grep 'worker' | awk '{print $1}'
}

function kube::worker::ips(){
    # Get a sequence of names; if you want an array, use additional parentheses ($(kube::worker::hostnames))
    kubectl get pods -o wide | grep worker | awk '{print $6}'
}

function chart::upgrade(){
    helm::check_installed

    # Install helm chart
    helm upgrade --wait --recreate-pods -f ${MYVALUES_FILE} \
        --timeout 900 --install ${RELEASE_NAME} . \
        --set limits.workers=$((NUM_NODES-1)) \
        --set limits.gpu=${NUM_GPUS} \
        --set limits.cpu=${NUM_CPUS}
}

function join_by(){
    local IFS="$1";
    shift; echo "$*";
}

function gcloud::cleanup(){
    gcloud::check_installed
    gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
    gcloud container clusters delete --quiet --zone ${MACHINE_ZONE}  ${CLUSTER_NAME}
}

case $1 in
    create-cluster)
        # Create a CPU cluster
        gcloud::check_installed

        if [ "$NUM_GPUS" -gt 0 ]; then
            gcloud container clusters create ${CLUSTER_NAME} \
                --zone=${MACHINE_ZONE} \
                --cluster-version=${CLUSTER_VERSION} \
                --enable-network-policy \
                --machine-type=${MACHINE_TYPE} \
                --accelerator type=${GPU_TYPE},count=${NUM_GPUS} \
                --num-nodes=${NUM_NODES} \
                --disk-type=${DISK_TYPE} \
                --disk-size=${INSTANCE_DISK_SIZE} \
                --scopes=storage-full

            kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml
        else
            gcloud container clusters create ${CLUSTER_NAME} \
                --zone=${MACHINE_ZONE} \
                --cluster-version=${CLUSTER_VERSION} \
                --enable-network-policy \
                --machine-type=${MACHINE_TYPE} \
                --num-nodes=${NUM_NODES} \
                --disk-type=${DISK_TYPE} \
                --disk-size=${INSTANCE_DISK_SIZE} \
                --scopes=storage-full
        fi


        # Get credential of the cluster
        gcloud container clusters get-credentials --zone ${MACHINE_ZONE} ${CLUSTER_NAME}

        kubectl --namespace kube-system create sa tiller

        kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller

        # Initialize helm to install charts
        helm::check_installed
        helm init --wait --service-account tiller
        ;;

    cleanup-cluster )
        gcloud::check_installed
        gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        gcloud container clusters delete --quiet --zone ${MACHINE_ZONE}  ${CLUSTER_NAME}
        ;;

    install-chart)
        chart::upgrade

        # setup firewall
        gcloud::check_installed
        export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services ${RELEASE_NAME}-mlbench-master)
        export NODE_IP=$(gcloud compute instances list|grep $(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}") |awk '{print $5}')
        gcloud compute firewall-rules create --quiet ${CLUSTER_NAME} --allow tcp:$NODE_PORT,tcp:$NODE_PORT
        echo "You can access MLBench at the following URL:"
        echo http://$NODE_IP:$NODE_PORT
        ;;

    upgrade-chart)
        chart::upgrade
        ;;


    uninstall-chart)
        gcloud::check_installed
        helm::check_installed
        helm delete --purge ${RELEASE_NAME}
        gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        ;;

    delete-cluster)
        gcloud::cleanup
        ;;

    get-credential)
        gcloud::get_credential
        ;;
    help)
        echo "$usage"
        ;;
    *)
        printf "illegal option: %s\n" "$1" >&2
        echo "$usage" >&2

esac
