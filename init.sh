#!/usr/bin/env bash

KAFKA_URL="https://archive.apache.org/dist/kafka/3.2.3/kafka_2.13-3.2.3.tgz"
STRIMZI_IMAGE="registry.redhat.io/amq7/amq-streams-kafka-32-rhel8:2.2.0"
NAMESPACE="test"

echo "Checking prerequisites"
if [[ -z $OCP_API_URL || -z $OCP_ADMIN_USR || -z $OCP_ADMIN_PWD ]]; then
  echo "Missing OpenShift parameters" && return 1
  exit 1
fi
for x in curl oc kubectl openssl keytool unzip yq jq git java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x" && return 1
    exit 1
  fi
done

echo "Getting Kafka from $KAFKA_URL"
pkill -f "kafka.Kafka" ||true
pkill -f "quorum.QuorumPeerMain" ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper
KAFKA_HOME="$(mktemp -d -t kafka.XXXXXXX)" && export KAFKA_HOME
curl -sLk "$KAFKA_URL" | tar xz -C "$KAFKA_HOME" --strip-components 1
PATH="$KAFKA_HOME/bin:$PATH" && export PATH

# find coordinating partition (JDK 9+ required)
find_cp() {
  local id="$1"
  local part="${2-50}"
  if [[ -n $id && -n $part ]]; then
    echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
      private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
      run("'"$id"'", '"$part"');' \
      | jshell -
  fi
}

echo "Authenticating to $OCP_API_URL"
oc login -u "$OCP_ADMIN_USR" -p "$OCP_ADMIN_PWD" "$OCP_API_URL" --insecure-skip-tls-verify=true &>/dev/null
kubectl config set-context --current --namespace=$NAMESPACE &>/dev/null

echo "Deploying cluster-wide operators"
kubectl delete ns $NAMESPACE &>/dev/null ||true
kubectl -n openshift-operators delete csv --all &>/dev/null ||true
kubectl -n openshift-operators delete sub --all &>/dev/null ||true
kubectl create ns $NAMESPACE
kubectl create -f sub.yaml

krun_kafka() { kubectl run krun-"$(date +%s)" -it --rm --restart="Never" --image="$STRIMZI_IMAGE" -- "$@"; }

echo "Environment READY!"
echo "  |__Kafka home: $KAFKA_HOME"
echo "  |__Current namespace: $NAMESPACE"
