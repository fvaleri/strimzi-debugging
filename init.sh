#!/usr/bin/env bash
# Source this file to configure your bash environment.
# Use --skip-local or --skip-ocp if you only need one configuration.

INIT_KAFKA_VERSION="3.2.3"
INIT_KAFKA_IMAGE="registry.redhat.io/amq7/amq-streams-kafka-32-rhel8:2.2.1"
INIT_OPERATOR_NS="openshift-operators"
INIT_TEST_NS="test"
INIT_SUBS_YAML="
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-streams
  namespace: openshift-operators
spec:
  channel: amq-streams-2.2.x
  name: amq-streams
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
      - name: FIPS_MODE
        value: disabled
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-registry
  namespace: openshift-operators
spec:
  channel: 2.x
  name: service-registry-operator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
"

[[ $1 == "--skip-local" ]] && INIT_LOCAL=false || INIT_LOCAL=true
[[ $1 == "--skip-ocp" ]] && INIT_OCP=false || INIT_OCP=true

echo "Checking prerequisites"
for x in curl oc kubectl openssl keytool unzip yq jq git java javac jshell mvn; do
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

if $INIT_LOCAL; then
  echo "Configuring Kafka on localhost"
  pkill -9 -f "kafka.Kafka" ||true
  pkill -9 -f "quorum.QuorumPeerMain" ||true
  rm -rf /tmp/kafka-logs /tmp/zookeeper
  get-kafka
  echo "Kafka home: $KAFKA_HOME"
  echo "Localhost OK"
fi

kafka-cp() {
  local id="${1-}" part="${2-50}"
  if [[ -z $id ]]; then echo "Missing id parameter" && return; fi
  echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
    private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
    run("'"$id"'", '"$part"');' | jshell -
}

oc-login() {
  local file="/tmp/ocp-login"
  if [[ ! -f $file ]]; then
    local ocp_url ocp_usr ocp_pwd
    printf "API URL: " && read -r ocp_url
    printf "Username: " && read -r ocp_usr
    printf "Password: " && read -rs ocp_pwd && echo ""
    declare -px ocp_url ocp_usr ocp_pwd > "$file"
  else
    # shellcheck source=/dev/null
    source "$file"
    if [[ -z $ocp_url || -z $ocp_usr || -z $ocp_pwd ]]; then
      echo "Missing login parameters" && return 1
    fi
  fi
  if oc login -u "$ocp_usr" -p "$ocp_pwd" "$ocp_url" --insecure-skip-tls-verify=true &>/dev/null; then
    return
  else
    echo "Login failed"
    rm -rf $file
    return 1
  fi
}

if $INIT_OCP; then
  echo "Configuring Kafka on OpenShift"
  if oc-login; then
    kubectl delete ns "$INIT_TEST_NS" target --wait &>/dev/null
    kubectl wait --for=delete ns/"$INIT_TEST_NS" --timeout=120s &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete csv -l "operators.coreos.com/amq-streams.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete csv -l "operators.coreos.com/service-registry-operator.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete sub -l "operators.coreos.com/amq-streams.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete sub -l "operators.coreos.com/service-registry-operator.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete pv -l "app=retain-patch" &>/dev/null

    kubectl create ns "$INIT_TEST_NS"
    kubectl config set-context --current --namespace="$INIT_TEST_NS" &>/dev/null
    echo -e "$INIT_SUBS_YAML" | kubectl create -f -

    krun() { kubectl run krun-"$(date +%s)" -itq --rm --restart="Never" --image="$INIT_KAFKA_IMAGE" -- sh -c "bin/$*"; }
    echo "OpenShift OK"
  fi
fi
