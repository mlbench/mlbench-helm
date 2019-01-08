#!/bin/sh

gcloud container clusters create pytorch-cifar10 --machine-type='n1-standard-2' --accelerator type=nvidia-tesla-k80,count=1 --region europe-west1-b --cluster-version=1.10.9 --num-nodes=17

gcloud container clusters get-credentials pytorch-cifar10 --zone=europe-west1-b

kubectl --namespace kube-system create sa tiller

kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller

helm init --wait --service-account tiller

kubectl apply --wait=true -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/stable/nvidia-driver-installer/cos/daemonset-preloaded.yaml

helm upgrade --install --wait --recreate-pods -f myvalues.yaml --timeout 900 --install rel .

export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services rel-mlbench-master)
export NODE_IP=$(gcloud compute instances list|grep $(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}") |awk '{print $5}')
echo http://$NODE_IP:$NODE_PORT
gcloud compute firewall-rules delete --quiet mlbench
gcloud compute firewall-rules create --quiet mlbench --allow tcp:$NODE_PORT,tcp:$NODE_PORT