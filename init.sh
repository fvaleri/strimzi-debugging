#!/usr/bin/env bash

NAMESPACE="test"
KAFKA_VERSION="3.7.1"
STRIMZI_VERSION="0.42.0"

if [[ "${BASH_SOURCE[0]}" -ef "$0" ]]; then
  echo "Source this script, not execute it"; exit 1
fi

for x in curl kubectl openssl keytool unzip yq jq java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x"; return 1
  fi
done

kafka-cp() {
  local id="${1-}" part="${2-50}"
  if [[ -z $id ]]; then echo "Missing id parameter"; return; fi
  echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$id"'", '"$part"');' | jshell -
}

kubectl-kafka() { kubectl run kubectl-kafka-"$(date +%s)" -itq --rm --restart="Never" \
  --image="apache/kafka:$KAFKA_VERSION" -- sh -c "/opt/kafka/$*; exit 0"; }
  
echo "Configuring Kafka on localhost"

# delete previous processes and data
pkill -9 -f "kafka.Kafka" &>/dev/null ||true
pkill -9 -f "quorum.QuorumPeerMain" &>/dev/null ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper

# get Kafka
KAFKA_HOME="/tmp/kafka-$KAFKA_VERSION" && export KAFKA_HOME
if [[ ! -d $KAFKA_HOME ]]; then
  echo "Downloading Kafka to $KAFKA_HOME"
  mkdir -p "$KAFKA_HOME"
  curl -sLk "https://archive.apache.org/dist/kafka/$KAFKA_VERSION/kafka_2.13-$KAFKA_VERSION.tgz" | tar xz -C "$KAFKA_HOME" --strip-components 1
fi

echo "Configuring Strimzi on Kubernetes"

# create the test namespace
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null
kubectl delete kt --all &>/dev/null && kubectl get kt -o yaml 2>/dev/null | yq 'del(.items[].metadata.finalizers[])' | kubectl apply -f - &>/dev/null
kubectl delete ns "$NAMESPACE" --ignore-not-found --force --wait=false &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null && kubectl create ns "$NAMESPACE"

# set privileged SecurityStandard label for this namespace and configure it as current
kubectl label ns "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite &>/dev/null

# PersistentVolumes cleanup 
# shellcheck disable=SC2046
kubectl delete pv $(kubectl get pv 2>/dev/null | grep "my-cluster" | awk '{print $1}') --ignore-not-found --now --force &>/dev/null

# VolumeSnapshotContents cleanup
# shellcheck disable=SC2046
kubectl delete pv $(kubectl get vsc 2>/dev/null | grep "my-cluster" | awk '{print $1}') --ignore-not-found --now --force &>/dev/null

# get Strimzi
STRIMZI_FILE="/tmp/strimzi-$STRIMZI_VERSION.yaml"
if [[ ! -f "$STRIMZI_FILE" ]]; then
  echo "Downloading Strimzi to $STRIMZI_FILE"
  curl -sLk "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" -o "$STRIMZI_FILE"
fi
sed -E "s/namespace: .*/namespace: $NAMESPACE/g" "$STRIMZI_FILE" | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null

echo "Done"
