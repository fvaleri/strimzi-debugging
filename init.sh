#!/usr/bin/env bash

NAMESPACE="test"
KAFKA_VERSION="3.5.1"
STRIMZI_VERSION="0.37.0"

if [[ "${BASH_SOURCE[0]}" -ef "$0" ]]; then
  echo "Source this script, not execute it"; exit 1
fi

for x in curl kubectl openssl keytool unzip yq jq java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x"; return 1
  fi
done

get-kafka() {
  local home && home="$(find /tmp -name 'kafka.*' -printf '%T@ %p\n' 2>/dev/null |sort -n |tail -n1 |awk '{print $2}')"
  if [[ -n $home ]]; then
    local version && version="$("$home"/bin/kafka-topics.sh --version 2>/dev/null |awk '{print $1}')"
    if [[ $version == "$KAFKA_VERSION" ]]; then
      echo "Getting Kafka from /tmp"
      KAFKA_HOME="$home" && export KAFKA_HOME
      return
    fi
  fi
  echo "Getting Kafka from ASF"
  KAFKA_HOME="/tmp/kafka-test" && export KAFKA_HOME
  rm -rf "$KAFKA_HOME" /tmp/kafka-logs /tmp/zookeeper; mkdir -p "$KAFKA_HOME"
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
  --image="quay.io/strimzi/kafka:latest-kafka-$KAFKA_VERSION" -- sh -c "$*; exit 0"; }

echo "Configuring Kafka on localhost"
pkill -9 -f "kafka.Kafka" &>/dev/null ||true
pkill -9 -f "quorum.QuorumPeerMain" &>/dev/null ||true
get-kafka
echo "Kafka home: $KAFKA_HOME"
echo "Done"

echo "Configuring Kafka on Kubernetes"
kubectl delete ns "$NAMESPACE" --wait &>/dev/null
kubectl wait --for=delete ns/"$NAMESPACE" --timeout=120s &>/dev/null
kubectl create ns "$NAMESPACE"
kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null
# deploy cluster-wide operator
kubectl create clusterrolebinding strimzi-cluster-operator-namespaced \
  --clusterrole strimzi-cluster-operator-namespaced --serviceaccount "$NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl create clusterrolebinding strimzi-cluster-operator-watched \
  --clusterrole strimzi-cluster-operator-watched --serviceaccount "$NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl create clusterrolebinding strimzi-cluster-operator-entity-operator-delegation \
  --clusterrole strimzi-entity-operator --serviceaccount "$NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
curl -sL "https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-cluster-operator-$STRIMZI_VERSION.yaml" \
  | sed -E "s/namespace: .*/namespace: $NAMESPACE/g" | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl set env deploy strimzi-cluster-operator STRIMZI_NAMESPACE="*" &>/dev/null
echo "Done"
