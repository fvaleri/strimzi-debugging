#!/usr/bin/env bash

# stop if not interactive mode
[[ $- != *i* ]] && echo "Usage: source init.sh" && exit 1

export NAMESPACE="test"
export STRIMZI_VERSION="0.47.0"
STRIMZI_FILE="/tmp/strimzi-$STRIMZI_VERSION.yaml"

kafka-cp() {
  local id="${1-}" part="${2-50}"
  echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$id"'", '"$part"');' | jshell -
}

kubectl-kafka() {
  kubectl get po kafka-tools &>/dev/null || kubectl run kafka-tools -q --restart="Never" \
    --image="apache/kafka:latest" -- sh -c "trap : TERM INT; sleep infinity & wait"
  kubectl wait --for=condition=ready po kafka-tools &>/dev/null
  kubectl exec kafka-tools -itq -- sh -c "/opt/kafka/$*"
}

kubectl-dns() {
  local ns="${1-}"
  kubectl delete ns "$ns" --wait=false &>/dev/null && sleep 10
  # delete namespace and topic finalizers that may block deletion
  kubectl get ns "$ns" --ignore-not-found -o yaml | yq 'del(.metadata.finalizers[])' | kubectl replace -f - &>/dev/null
  kubectl get kt --ignore-not-found -o yaml | yq 'del(.items[].metadata.finalizers[])' | kubectl replace -f - &>/dev/null
  kubectl wait --for=delete ns/"$ns" --timeout=120s &>/dev/null
}

echo "Connecting to Kubernetes"
if ! kubectl cluster-info &>/dev/null; then echo "Unable to connect to Kubernetes" && return; fi
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null

echo "Creating namespace $NAMESPACE"
kubectl-dns "$NAMESPACE"
kubectl create ns "$NAMESPACE" &>/dev/null
# set privileged SecurityStandard label for this namespace
kubectl label ns "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite &>/dev/null

echo "Deleting strays volumes"
kubectl delete pv $(kubectl get pv 2>/dev/null | grep "my-cluster" | awk "{print $1}") --ignore-not-found &>/dev/null

echo "Installing operator $STRIMZI_VERSION"
if [[ ! -f "$STRIMZI_FILE" ]]; then
  curl -sLk "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" -o "$STRIMZI_FILE"
fi
sed -E "s/namespace: .*/namespace: $NAMESPACE/g ; s/memory: .*/memory: 500Mi/g" "$STRIMZI_FILE" | kubectl replace --force -f - &>/dev/null
kubectl wait --for=condition=Available deploy strimzi-cluster-operator --timeout=300s &>/dev/null
