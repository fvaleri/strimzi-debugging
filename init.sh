#!/usr/bin/env bash

NAMESPACE="test" && export NAMESPACE
STRIMZI_VERSION="0.46.0" && export STRIMZI_VERSION

[[ "${BASH_SOURCE[0]}" -ef "$0" ]] && echo "Usage: source init.sh" && exit 1

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

echo "Deploying Strimzi"

# create test namespace
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null

# delete any topic first to clean finalizers
kubectl get kt -o yaml 2>/dev/null | yq 'del(.items[].metadata.finalizers[])' \
  | kubectl apply -f - &>/dev/null; kubectl delete kt --all --force &>/dev/null

kubectl delete ns "$NAMESPACE" --ignore-not-found --force --wait=false &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null && kubectl create ns "$NAMESPACE"

# set privileged SecurityStandard label for this namespace
kubectl label ns "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite &>/dev/null

# clean PersistentVolumes
# shellcheck disable=SC2046
kubectl delete pv $(kubectl get pv 2>/dev/null | grep "my-cluster" | awk '{print $1}') --force &>/dev/null

# clean monitoring stack
kubectl delete ns grafana prometheus --force --wait=false &>/dev/null
kubectl delete crd $(kubectl get crd 2>/dev/null | grep integreatly.org | awk '{print $1}') &>/dev/null
kubectl delete crd $(kubectl get crd 2>/dev/null | grep monitoring.coreos.com | awk '{print $1}') &>/dev/null

# deploy Strimzi
STRIMZI_FILE="/tmp/strimzi-$STRIMZI_VERSION.yaml"
if [[ ! -f "$STRIMZI_FILE" ]]; then
  echo "Downloading Strimzi to $STRIMZI_FILE"
  curl -sLk "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" -o "$STRIMZI_FILE"
fi
sed -E "s/namespace: .*/namespace: $NAMESPACE/g ; s/memory: .*/memory: 500Mi/g" "$STRIMZI_FILE" \
  | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl set env deploy/strimzi-cluster-operator STRIMZI_FULL_RECONCILIATION_INTERVAL_MS="30000" &>/dev/null

kubectl wait --for=condition=Available deploy strimzi-cluster-operator --timeout=300s
echo "Done"
