#!/usr/bin/env bash
# Source this file to configure your bash environment.

INIT_NAMESPACE="test"
INIT_KAFKA_VERSION="3.5.1"
INIT_STRIMZI_VERSION="0.37.0"
INIT_KAFKA_IMAGE="quay.io/strimzi/kafka:latest-kafka-$INIT_KAFKA_VERSION"
INIT_DEPLOY_URL="https://github.com/strimzi/strimzi-kafka-operator/\
releases/download/$INIT_STRIMZI_VERSION/strimzi-cluster-operator-$INIT_STRIMZI_VERSION.yaml"

for x in curl kubectl openssl keytool unzip yq jq java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x" && return 1
  fi
done

get-kafka() {
  local home && home="$(find /tmp -name 'kafka.*' -printf '%T@ %p\n' 2>/dev/null |sort -n |tail -n1 |awk '{print $2}')"
  if [[ -n $home ]]; then
    local version && version="$("$home"/bin/kafka-topics.sh --version 2>/dev/null |awk '{print $1}')"
    if [[ $version == "$INIT_KAFKA_VERSION" ]]; then
      echo "Getting Kafka from /tmp"
      KAFKA_HOME="$home" && export KAFKA_HOME
      return
    fi
  fi
  echo "Getting Kafka from ASF"
  KAFKA_HOME="$(mktemp -d -t kafka.XXXXXXX)" && export KAFKA_HOME
  curl -sLk "https://archive.apache.org/dist/kafka/$INIT_KAFKA_VERSION/kafka_2.13-$INIT_KAFKA_VERSION.tgz" \
    | tar xz -C "$KAFKA_HOME" --strip-components 1
}

kafka-cp() {
  local id="${1-}" part="${2-50}"
  if [[ -z $id ]]; then echo "Missing id parameter" && return; fi
  echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$id"'", '"$part"');' | jshell -
}

krun() { kubectl run krun-"$(date +%s)" -itq --rm --restart="Never" \
  --image="$INIT_KAFKA_IMAGE" -- sh -c "/opt/kafka/bin/$*; exit 0"; }

echo "Configuring Kafka on localhost"
pkill -9 -f "kafka.Kafka" ||true
pkill -9 -f "quorum.QuorumPeerMain" ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper
get-kafka
echo "Kafka home: $KAFKA_HOME"
echo "Done"

echo "Configuring Kafka on Kubernetes"
kubectl delete ns "$INIT_NAMESPACE" "$INIT_NAMESPACE"-tgt --wait &>/dev/null
kubectl wait --for=delete ns/"$INIT_NAMESPACE" --timeout=120s &>/dev/null
kubectl -n "$INIT_OPERATOR_NS" delete pv -l "app=retain-patch" &>/dev/null
kubectl create ns "$INIT_NAMESPACE"
kubectl create ns "$INIT_NAMESPACE"-tgt
kubectl config set-context --current --namespace="$INIT_NAMESPACE" &>/dev/null
# deploy cluster-wide operator
kubectl create clusterrolebinding strimzi-cluster-operator-namespaced \
  --clusterrole strimzi-cluster-operator-namespaced --serviceaccount "$INIT_NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl create clusterrolebinding strimzi-cluster-operator-watched \
  --clusterrole strimzi-cluster-operator-watched --serviceaccount "$INIT_NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl create clusterrolebinding strimzi-cluster-operator-entity-operator-delegation \
  --clusterrole strimzi-entity-operator --serviceaccount "$INIT_NAMESPACE":strimzi-cluster-operator \
  --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
curl -sL "$INIT_DEPLOY_URL" | sed -E "s/namespace: .*/namespace: $INIT_NAMESPACE/g" \
  | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f - &>/dev/null
kubectl set env deploy strimzi-cluster-operator STRIMZI_NAMESPACE="*" &>/dev/null
echo "Done"
