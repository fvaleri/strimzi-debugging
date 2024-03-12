#!/usr/bin/env bash

NAMESPACE="test"
KAFKA_VERSION="3.6.0"
STRIMZI_VERSION="0.38.0"

if [[ "${BASH_SOURCE[0]}" -ef "$0" ]]; then
  echo "Source this script, not execute it"; exit 1
fi

for x in curl kubectl openssl keytool unzip yq jq java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x"; return 1
  fi
done

get-kafka() {
  KAFKA_HOME="/tmp/kafka-test" && mkdir -p "$KAFKA_HOME" && export KAFKA_HOME
  local version && version="$("$KAFKA_HOME"/bin/kafka-topics.sh --version 2>/dev/null |awk '{print $1}')"
  if [[ $version == "$KAFKA_VERSION" ]]; then
    echo "Reusing Kafka in $KAFKA_HOME"
    return
  fi
  echo "Downloading Kafka to $KAFKA_HOME"
  curl -sLk "https://archive.apache.org/dist/kafka/$KAFKA_VERSION/kafka_2.13-$KAFKA_VERSION.tgz" \
    | tar xz -C "$KAFKA_HOME" --strip-components 1
}

kafka-cp() {
  local id="${1-}" part="${2-50}"
  if [[ -z $id ]]; then echo "Missing id parameter"; return; fi
  echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$id"'", '"$part"');' | jshell -
}

kubectl-kafka() { kubectl run kubectl-kafka-"$(date +%s)" -itq --rm --restart="Never" \
  --image="quay.io/strimzi/kafka:latest-kafka-$KAFKA_VERSION" -- sh -c "/opt/kafka/$*; exit 0"; }

echo "Configuring Kafka on localhost"
pkill -9 -f "kafka.Kafka" &>/dev/null ||true
pkill -9 -f "quorum.QuorumPeerMain" &>/dev/null ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper
get-kafka
echo "Done"

echo "Configuring Kafka on Kubernetes"
kubectl delete ns "$NAMESPACE" --force --wait --ignore-not-found &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null && kubectl create ns "$NAMESPACE"
PVS=$(kubectl get pv 2>/dev/null | grep "my-cluster\|Available" | awk '{print $1}'); if [[ -n "$PVS" ]]; then kubectl delete pv "$PVS" &>/dev/null; fi
VSCS=$(kubectl get vsc 2>/dev/null | grep "my-cluster" | awk '{print $1}'); if [[ -n "$VSCS" ]]; then kubectl delete vsc "$VSCS" &>/dev/null \
  && kubectl patch vsc "$VSCS" --type json --patch='[{"op":"remove","path":"/metadata/finalizers"}]' &>/dev/null; fi
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null
curl -sL "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" \
  | sed -E "s/namespace: .*/namespace: $NAMESPACE/g" | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
echo "Done"
