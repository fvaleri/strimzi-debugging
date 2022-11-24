# Source this file to initialize or reset
# the workspace after running an example.
# Pass --skip-ocp if you only need local Kafka.

echo "Checking prerequisites"
for x in curl oc kubectl openssl keytool unzip yq jq git java javac jshell mvn; do
  if ! command -v "$x" &>/dev/null; then
    echo "Missing required utility: $x" && return 1
  fi
done

# shared state
INIT_HOME="" && pushd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null \
  && { INIT_HOME=$PWD; popd >/dev/null || exit; }
INIT_KAFKA_VERSION="3.2.3"
INIT_STRIMZI_IMAGE="registry.redhat.io/amq7/amq-streams-kafka-32-rhel8:2.2.0"
INIT_OPERATOR_NS="openshift-operators"
INIT_TEST_NS="test"

add_path() {
  if [[ -d "$1" && ":$PATH:" != *":$1:"* ]]; then
    PATH="${PATH:+"$PATH:"}$1"
  fi
}

get_kafka() {
  local home && home="$(find /tmp -name 'kafka.*' -printf '%T@ %p\n' 2>/dev/null |sort -n |tail -n1 |awk '{print $2}')"
  if [[ -n $home ]]; then
    local version && version="$("$home"/bin/kafka-topics.sh --version 2>/dev/null |awk '{print $1}')"
    if [[ $version == "$INIT_KAFKA_VERSION" ]]; then
      echo "Getting Kafka from /tmp"
      KAFKA_HOME="$home" && export KAFKA_HOME && add_path "$KAFKA_HOME/bin"
      return
    fi
  fi
  echo "Getting Kafka from ASF"
  KAFKA_HOME="$(mktemp -d -t kafka.XXXXXXX)" && export KAFKA_HOME && add_path "$KAFKA_HOME/bin"
  curl -sLk "https://archive.apache.org/dist/kafka/$INIT_KAFKA_VERSION/kafka_2.13-$INIT_KAFKA_VERSION.tgz" \
    | tar xz -C "$KAFKA_HOME" --strip-components 1
}

pkill -f "kafka.Kafka" ||true
pkill -f "quorum.QuorumPeerMain" ||true
rm -rf /tmp/kafka-logs /tmp/zookeeper
get_kafka
echo "Kafka home: $KAFKA_HOME"

find_cp() {
  local id="$1" part="${2-50}"
  if [[ -n $id && -n $part ]]; then
    echo 'public void run(String id, int part) { System.out.println(abs(id.hashCode()) % part); }
      private int abs(int n) { return (n == Integer.MIN_VALUE) ? 0 : Math.abs(n); }
      run("'"$id"'", '"$part"');' | jshell -
  fi
}

authn_ocp() {
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

[[ $1 = "--skip-ocp" ]] && SKIP_OCP=true || SKIP_OCP=false
if [[ $SKIP_OCP != true ]]; then
  echo "Configuring OpenShift"
  if authn_ocp; then
    kubectl delete ns "$INIT_TEST_NS" target --wait &>/dev/null
    kubectl wait --for=delete ns/"$INIT_TEST_NS" --timeout=120s &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete csv -l "operators.coreos.com/amq-streams.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete csv -l "operators.coreos.com/service-registry-operator.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete sub -l "operators.coreos.com/amq-streams.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete sub -l "operators.coreos.com/service-registry-operator.$INIT_OPERATOR_NS" &>/dev/null
    kubectl -n "$INIT_OPERATOR_NS" delete pv -l "app=retain-patch" &>/dev/null

    kubectl create ns "$INIT_TEST_NS"
    kubectl config set-context --current --namespace="$INIT_TEST_NS" &>/dev/null
    kubectl create -f "$INIT_HOME"/sub.yaml

    krun() { kubectl run krun-"$(date +%s)" -itq --rm --restart="Never" --image="$INIT_STRIMZI_IMAGE" -- /opt/kafka/bin/"$@"; }
  fi
fi

echo "READY!"
