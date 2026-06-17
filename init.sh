#!/usr/bin/env bash

# stop if not interactive mode
[[ $- != *i* ]] && echo "Usage: source init.sh" && exit 1

export NAMESPACE="test"
export STRIMZI_VERSION="1.0.1"
STRIMZI_FILE="/tmp/strimzi-$STRIMZI_VERSION.yaml"
CLUSTER_NAME="my-cluster"

# get coordinating partition
get-cp() {
  local key="${1-}" num_parts="${2-50}"
  echo 'public void run(String key, int numParts) { System.out.println(abs(key.hashCode()) % numParts); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$key"'", '"$num_parts"');' | jshell -
}

# run kafka tools in a dedicated pod
kubectl-kafka() {
  kubectl get po kafka-tools &>/dev/null || kubectl run kafka-tools -q --restart="Never" \
    --image="apache/kafka:latest" -- sh -c "trap : TERM INT; sleep infinity & wait"
  kubectl wait --for=condition=ready po kafka-tools &>/dev/null
  kubectl exec kafka-tools -itq -- sh -c "/opt/kafka/$*"
}

if ! kubectl cluster-info &>/dev/null; then
  echo "Unable to connect to Kubernetes" && return
fi

echo "Creating namespace $NAMESPACE"
# delete namespace and topic finalizers that may block deletion
kubectl delete ns "$NAMESPACE" --wait=false &>/dev/null && sleep 10
kubectl get ns "$NAMESPACE" --ignore-not-found -o yaml | yq 'del(.metadata.finalizers[])' | kubectl replace -f - &>/dev/null
kubectl get kt --ignore-not-found -o yaml 2>/dev/null | yq 'del(.items[].metadata.finalizers[])' | kubectl replace -f - &>/dev/null
kubectl get apicurioregistries3 --ignore-not-found -o yaml 2>/dev/null | yq 'del(.items[].metadata.finalizers[])' | kubectl replace -f - &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null
# create a new namespace
kubectl create ns "$NAMESPACE" &>/dev/null
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null
# set privileged SecurityStandard label for this namespace
kubectl label ns "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite &>/dev/null
# delete strays volumes
kubectl delete pv $(kubectl get pv 2>/dev/null | grep "$CLUSTER_NAME" | awk '{print $1}') &>/dev/null ||true

echo "Installing Strimzi $STRIMZI_VERSION"
if [[ ! -f "$STRIMZI_FILE" ]]; then
  curl -sLk "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" -o "$STRIMZI_FILE"
fi
sed -E "s/namespace: .*/namespace: $NAMESPACE/g" "$STRIMZI_FILE" | kubectl replace --force -f - &>/dev/null
kubectl wait --for=condition=Available deploy strimzi-cluster-operator --timeout=300s &>/dev/null
