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
DEV_NAME=${DEV_NAME:-/dev/sdh}

MACHINE_ZONE=${MACHINE_ZONE:-us-east1-b}
MYVALUES_FILE=${MYVALUES_FILE:-config.yaml}
KEY_NAME=${KEY_NAME:-MyKey}
SECURITY_GROUP=${SECURITY_GROUP:-EC2SecurityGroup}

IMAGE_ID=${IMAGE_ID:-ami-075b44448d2276521}
MACHINE_TYPE=${MACHINE_TYPE:-t2.micro}
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

function kubectl::check_installed(){
    if ! [-x "$(command -v kubectl)"]; then
        echo "Installing kubectl"
        curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
        chmod +x ./kubectl
        #should use sudo? what if no admin priviledges? easier to install with 'sudo snap install kubectl --classic'
        sudo mv ./kubectl /usr/local/bin/kubectl
    fi
}

function aws::check_installed(){
    if ! [ -x "$(command -v aws)" ]; then
        echo "Installing AWS CLI"

    # download and install aws cli
	curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
	unzip awscli-bundle.zip
	./awscli-bundle/install -b ~/bin/aws

    # generate access credentials
    aws iam create-group --group-name kops
    aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --group-name kops

    aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess --group-name kops
    aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --group-name kops
    aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/IAMFullAccess --group-name kops
    aws iam attach-group-policy --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess --group-name kops
    
    aws iam create-user --user-name kops
    aws iam add-user-to-group --user-name kops --group-name kops
    aws iam create-access-key --user-name kops

    # configure access credentials, may require use input
    aws configure

    # export env variables for kops to use
    export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
    fi
}

function helm::check_installed(){
    if ! [ -x "$(command -v helm)" ]; then
        echo "Installing Helm"

        # curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
        source <(curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get)
    fi
}

function kops::check_installed(){
    if ! [ -x "$(command -v kops)" ]; then
        curl -Lo kops https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | grep tag_name | cut -d '"' -f 4)/kops-linux-amd64
        chmod +x ./kops
        sudo mv ./kops /usr/local/bin/
    fi
}

function aws::get_credential(){
    aws::check_installed
    kubectl::check_installed
    cat ~/.kube/config
    cat ~/.aws/credentials
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

function aws::cleanup(){
    aws::check_installed
    gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
    gcloud container clusters delete --quiet --zone ${MACHINE_ZONE}  ${CLUSTER_NAME}
}

case $1 in
    create-cluster)
        # Create a CPU cluster
        aws::check_installed

        # create store for state of cluster with an S3 bucket, ground truth for cluster config
        # use us-east-1 otherwise more work is required
        aws s3api create-bucket \
            --bucket ${CLUSTER_NAME}-state-store \
            --region us-east-1

        # enable store versioning
        aws s3api put-bucket-versioning --bucket ${CLUSTER_NAME}-state-store \ 
            --versioning-configuration Status=Enabled

        # use default bucket encryption
        aws s3api put-bucket-encryption --bucket ${CLUSTER_NAME}-state-store \ 
            --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

        export CLUSTER_NAME=${CLUSTER_NAME}.k8s.local
        export KOPS_STATE_STORE=s3://${CLUSTER_NAME}-state-store

        # may need aws ec2 describe-availability-zones --region us-west-2

        # using '.k8s.local' suffix for gossip-based cluster discovery 
        kops create cluster \
            --cloud aws \
            --zones ${MACHINE_ZONE} \
            --name ${CLUSTER_NAME}.k8s.local \
            --store s3://${CLUSTER_NAME}-state-store \
            --master-size "${MACHINE_TYPE}" \
            --node-size "${MACHINE_TYPE}" \
            --node-count ${NUM_NODES} \
            --image "ubuntu-os-cloud/ubuntu-1604-xenial-v20170202" \
            --yes

        #if [ "$NUM_GPUS" -gt 0 ]; then
        #    kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml
        #fi

        kubectl --namespace kube-system create sa tiller

        kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller

        # Initialize helm to install charts
        helm::check_installed
        helm init --wait --service-account tiller
        ;;

    cleanup-cluster )
        aws::check_installed
        #gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        kops delete cluster --name=${MACHINE_ZONE} --state=s3://${CLUSTER_NAME}-state-store
        ;;

    install-chart)
        chart::upgrade

        # setup firewall
        aws::check_installed
        export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services ${RELEASE_NAME}-mlbench-master)
        #export NODE_IP=$(gcloud compute instances list|grep $(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}") |awk '{print $5}')
        #gcloud compute firewall-rules create --quiet ${CLUSTER_NAME} --allow tcp:$NODE_PORT,tcp:$NODE_PORT
        echo "You can access MLBench at the following URL:"
        echo http://$NODE_IP:$NODE_PORT
        ;;

    upgrade-chart)
        chart::upgrade
        ;;


    uninstall-chart)
        aws::check_installed
        helm::check_installed
        helm delete --purge ${RELEASE_NAME}
        #gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        ;;

    delete-cluster)
        aws::cleanup
        ;;

    get-credential)
        aws::get_credential
        ;;
    help)
        echo "$usage"
        ;;
    *)
        printf "illegal option: %s\n" "$1" >&2
        echo "$usage" >&2

esac
