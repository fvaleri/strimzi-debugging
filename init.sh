#!/usr/bin/env bash

NAMESPACE="test"
KAFKA_VERSION="3.8.0"
STRIMZI_VERSION="0.43.0"

[[ "${BASH_SOURCE[0]}" -ef "$0" ]] && echo "Usage: source init.sh" && exit 1

for x in curl kubectl openssl keytool unzip yq jq java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x"; return 1
  fi
done

kafka-cp() {
  local id="${1-}" part="${2-50}"
  [[ -z $id ]] && echo "Missing params" && return
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
  
echo "Configuring Kafka on localhost"

# delete previous processes and data
pkill -9 -f "kafka.Kafka" &>/dev/null ||true
rm -rf /tmp/kraft-combined-logs

# get Kafka
KAFKA_HOME="/tmp/kafka-$KAFKA_VERSION" && export KAFKA_HOME
if [[ ! -d $KAFKA_HOME ]]; then
  echo "Downloading Kafka to $KAFKA_HOME"
  mkdir -p "$KAFKA_HOME"
  curl -sLk "https://archive.apache.org/dist/kafka/$KAFKA_VERSION/kafka_2.13-$KAFKA_VERSION.tgz" | tar xz -C "$KAFKA_HOME" --strip-components 1
fi

echo "Configuring Strimzi on Kubernetes"

# create test namespace
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null

# delete topics first, as they contain finalizers
kubectl get kt -o yaml 2>/dev/null | yq 'del(.items[].metadata.finalizers[])' | kubectl apply -f - &>/dev/null; kubectl delete kt --all --force &>/dev/null

kubectl delete ns "$NAMESPACE" --ignore-not-found --force --wait=false &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null && kubectl create ns "$NAMESPACE"

# set privileged SecurityStandard label for this namespace
kubectl label ns "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite &>/dev/null

# PersistentVolumes cleanup
# shellcheck disable=SC2046
kubectl delete pv $(kubectl get pv 2>/dev/null | grep "my-cluster" | awk '{print $1}') --ignore-not-found --force &>/dev/null

# get Strimzi
STRIMZI_FILE="/tmp/strimzi-$STRIMZI_VERSION.yaml"
if [[ ! -f "$STRIMZI_FILE" ]]; then
  echo "Downloading Strimzi to $STRIMZI_FILE"
  curl -sLk "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" -o "$STRIMZI_FILE"
fi
sed -E "s/namespace: .*/namespace: $NAMESPACE/g" "$STRIMZI_FILE" | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null

echo "Done"
