curl -LO https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
chmod +x ./kubectl && sudo mv ./kubectl /usr/local/bin/kubectl
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
curl https://raw.githubusercontent.com/zlabjp/kubernetes-scripts/master/wait-until-pods-ready > wait_until_pods_ready.sh
chmod +x wait_until_pods_ready.sh
GO111MODULE="on" go get sigs.k8s.io/kind@$KIND_VERSION && kind create cluster --image $KIND_NODE_IMAGE


kubectl cluster-info
kubectl version
helm template travis-test-2 . --set limits.cpu=1000m --set limits.workers=1 --set limits.gpu=0 | kubectl apply --validate -f -
sleep 2
./wait_until_pods_ready.sh 30 2
echo "Deployment successful"