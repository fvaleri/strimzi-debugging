#!/usr/bin/env bash
# source init.sh to initialize the env

KAFKA_VERSION="3.2.3"
STRIMZI_IMAGE="registry.redhat.io/amq7/amq-streams-kafka-32-rhel8:2.2.0"
NAMESPACE="test"

echo "Checking prerequisites"
for x in curl oc kubectl openssl keytool unzip yq jq git java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x" && return 1
  fi
done

get_kafka() {
  local home && home="$(find /tmp -name 'kafka.*' -printf '%T@ %p\n' 2>/dev/null |sort -n |tail -n1 |awk '{print $2}')"
  if [[ -n $home ]]; then
    local version && version="$("$home"/bin/kafka-topics.sh --version 2>/dev/null |awk '{print $1}')"
    if [[ $version == "$KAFKA_VERSION" ]]; then
      echo "Getting Kafka from /tmp"
      KAFKA_HOME="$home" && export KAFKA_HOME \
        && PATH="$KAFKA_HOME/bin:$PATH" && export PATH
      PATH="$KAFKA_HOME/bin:$PATH" && export PATH
      return
    fi
  fi
  echo "Getting Kafka from ASF"
  KAFKA_HOME="$(mktemp -d -t kafka.XXXXXXX)" && export KAFKA_HOME \
    && PATH="$KAFKA_HOME/bin:$PATH" && export PATH
  curl -sLk "https://archive.apache.org/dist/kafka/$KAFKA_VERSION/kafka_2.13-$KAFKA_VERSION.tgz" \
    | tar xz -C "$KAFKA_HOME" --strip-components 1
}

pkill -f "kafka.Kafka" ||true
pkill -f "quorum.QuorumPeerMain" ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper
get_kafka

# find coordinating partition (JDK 9+ required)
find_cp() {
  local id="$1"
  local part="${2-50}"
  if [[ -n $id && -n $part ]]; then
    echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
      private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
      run("'"$id"'", '"$part"');' | jshell -
  fi
}

authn_ocp() {
  echo "Authenticating to OpenShift"
  local file="/tmp/ocp-login"
  if [[ ! -f $file ]]; then
    local ocp_url ocp_usr ocp_pwd
    printf "API URL: " && read ocp_url
    printf "Username: " && read ocp_usr
    printf "Password: " && read -s ocp_pwd && echo ""
    declare -px ocp_url ocp_usr ocp_pwd > "$file"
  else
    # shellcheck source=/dev/null
    source "$file"
    if [[ -z $ocp_url || -z $ocp_usr || -z $ocp_pwd ]]; then
      echo "Missing OpenShift parameters" && return 1
    fi
  fi
  if oc login -u "$ocp_usr" -p "$ocp_pwd" "$ocp_url" --insecure-skip-tls-verify=true &>/dev/null; then
    return
  else
    echo "Authentication failed"
    rm -rf $file
    return 1
  fi
}

if authn_ocp; then
  kubectl config set-context --current --namespace="$NAMESPACE" &>/dev/null
  kubectl delete ns "$NAMESPACE" &>/dev/null ||true
  kubectl create ns "$NAMESPACE"
  kubectl -n openshift-operators delete csv --all &>/dev/null ||true
  kubectl -n openshift-operators delete sub --all &>/dev/null ||true
  kubectl create -f sub.yaml

  krun_kafka() { kubectl run krun-"$(date +%s)" -it --rm --restart="Never" --image="$STRIMZI_IMAGE" -- "$@"; }

  echo "Environment READY!
    |__ Kafka home: $KAFKA_HOME
    |__ Current namespace: $NAMESPACE"
fi
