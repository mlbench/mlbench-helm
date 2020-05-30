#!/bin/bash +x
set -e
usage="usage: aws_setup.sh <command>

commands:
    get-credential          Get aws credentials
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
    MACHINE_TYPE            Google Cloud instance type, default: 't2.medium'
    CLUSTER_VERSION         Kubernetes version, default: 1.10
    DISK_TYPE               Cloud storage type, default: 'pd-standard'
    INSTANCE_DISK_SIZE      Google instance size (GB), default: 50
    NUM_CPUS                Number of CPUs per instance, default: 1
    NUM_GPUS                Number of GPUs per instance, 0 to not use GPU instances, default: 0
    GPU_TYPE                The type of GPU to use, default: 'nvidia-tesla-p100'

    "

NUM_NODES=${NUM_NODES:-3}
PREFIX=${PREFIX:-rel}
RELEASE_NAME=${PREFIX}-${NUM_NODES}
CLUSTER_NAME=${PREFIX}-${NUM_NODES}b
DEV_NAME=${DEV_NAME:-/dev/sdh}

MACHINE_ZONE=${MACHINE_ZONE:-us-east-1b}
MYVALUES_FILE=${MYVALUES_FILE:-values.yaml}
KEY_NAME=${KEY_NAME:-MyKey}
SECURITY_GROUP=${SECURITY_GROUP:-EC2SecurityGroup}

IMAGE_ID=${IMAGE_ID:-ami-075b44448d2276521}
MACHINE_TYPE=${MACHINE_TYPE:-t2.medium}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.15}
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
    if ! [ -x "$(command -v kubectl)" ]; then
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
	./awscli-bundle/install -b ~/.local/bin/aws
	echo "export PATH=\$PATH:\$HOME/.local/bin" >> $HOME/.bashrc
    export PATH=$PATH:$HOME/.local/bin
	source $HOME/.bashrc

    # configure access credentials, may require use input
    aws configure

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

    # export env variables for kops to use
    export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)

    # cleanup installation package
    rm -r ./awscli-bundle/
    rm ./awscli-bundle.zip
    fi
}

function eksctl::check_installed(){
    if ! [ -x "$(command -v eksctl)" ]; then
        echo "Installing eksctl"

    	# download and install eksctl
	curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
	sudo mv /tmp/eksctl /usr/local/bin
    fi
}


function helm::check_installed(){
    if ! [ -x "$(command -v helm)" ]; then
        echo "Installing Helm"

        # curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
        source <(curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get)
    fi
}

function aws::get_credential(){
    aws::check_installed
    kubectl::check_installed
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
        --timeout 900s --install ${RELEASE_NAME} . \
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
    eksctl::check_installed
    eksctl delete cluster --name prod
}

case $1 in
    create-cluster)
        # Create a CPU cluster
        aws::check_installed
	eksctl::check_installed

        if [ ! -d ~/.ssh ]; then
            ssh-keygen
        fi

        eksctl create cluster \
		--name "${CLUSTER_NAME}" \
		--version ${KUBERNETES_VERSION} \
		--region ${MACHINE_ZONE} \
		--nodegroup-name standard-workers \
		--node-type "${MACHINE_TYPE}" \
		--nodes ${NUM_NODES} \
		--nodes-min $((NUM_NODES-1)) \
		--nodes-max $((NUM_NODES+1)) \
		--ssh-access \
		--managed

        #if [ "$NUM_GPUS" -gt 0 ]; then
        #    kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml
        #fi
        ;;

    cleanup-cluster )
        aws::check_installed
	eksctl::check_installed
        eksctl delete cluster --name "${CLUSTER_NAME}"
        ;;

    install-chart)
        chart::upgrade

        # setup firewall
        aws::check_installed
        export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services ${RELEASE_NAME}-mlbench-master)
        export NODE_IP=$(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}")
        export MAIN_MACHINE_ZONE=$(echo $MACHINE_ZONE | sed -e 's/\([a-z]\)*$//g')
        export GROUP_ID=$(aws ec2 describe-instances --region ${MAIN_MACHINE_ZONE} --filter Name=private-ip-address,Values=${NODE_IP} --query 'Reservations[].Instances[].[SecurityGroups][0][0][0].GroupId')
        export GROUP_ID=${GROUP_ID:1:-1}
        export NODE_IP=$(aws ec2 describe-instances --region ${MAIN_MACHINE_ZONE} --filter Name=private-ip-address,Values=${NODE_IP} --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress][0][1]')
        export NODE_IP=${NODE_IP:1:-1}
        #export VPC_ID=$(aws ec2 describe-instances --region ${MAIN_MACHINE_ZONE} --filter Name=private-ip-address,Values=${NODE_IP} --query 'Reservations[].Instances[].[VpcId][0][0]')
        #export VPC_ID=${VPC_ID:1:-1}
        aws ec2 authorize-security-group-ingress --region ${MAIN_MACHINE_ZONE} --group-id ${GROUP_ID} --protocol tcp --port ${NODE_PORT} --cidr 0.0.0.0/0

        echo "You can access MLBench at the following URL:"
        echo http://$NODE_IP:$NODE_PORT
        ;;

    upgrade-chart)
        chart::upgrade
        ;;


    uninstall-chart)
        aws::check_installed
        helm::check_installed
        export MAIN_MACHINE_ZONE=$(echo $MACHINE_ZONE | sed -e 's/\([a-z]\)*$//g')
        export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services ${RELEASE_NAME}-mlbench-master)
        export GROUP_ID=$(aws ec2 describe-instances --region ${MAIN_MACHINE_ZONE} --filter Name=private-ip-address,Values=${NODE_IP} --query 'Reservations[].Instances[].[SecurityGroups][0][0][0].GroupId')
        export GROUP_ID=${GROUP_ID:1:-1}
        aws ec2 rauthorize-security-group-ingress--region ${MAIN_MACHINE_ZONE} --group-id ${GROUP_ID} --protocol tcp --port ${NODE_PORT} --cidr 0.0.0.0/0
        helm delete --purge ${RELEASE_NAME}
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
