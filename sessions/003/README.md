## Getting Diagnostic Data

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

When debugging issues, we need to collect various artifacts from the environment, which can be time-consuming and error-prone.
Strimzi provides a must-gather script that simplifies this process by downloading all relevant artifacts and logs from a specific Kafka cluster.

> [!NOTE]  
> Add the `--secrets=all` option to also get secret values.

```sh
$ curl -s https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/"$STRIMZI_VERSION"/tools/report.sh \
  | bash -s -- --namespace=test --cluster=my-cluster --out-dir=~/Downloads
deployments
    deployment.apps/my-cluster-entity-operator
statefulsets
replicasets
    replicaset.apps/my-cluster-entity-operator-bb7c65dd4
configmaps
    configmap/my-cluster-broker-10
    configmap/my-cluster-broker-11
    configmap/my-cluster-broker-12
    configmap/my-cluster-controller-0
    configmap/my-cluster-controller-1
    configmap/my-cluster-controller-2
    configmap/my-cluster-entity-topic-operator-config
    configmap/my-cluster-entity-user-operator-config
secrets
    secret/my-cluster-clients-ca
    secret/my-cluster-clients-ca-cert
    secret/my-cluster-cluster-ca
    secret/my-cluster-cluster-ca-cert
    secret/my-cluster-cluster-operator-certs
    secret/my-cluster-entity-topic-operator-certs
    secret/my-cluster-entity-user-operator-certs
    secret/my-cluster-kafka-brokers
services
    service/my-cluster-kafka-bootstrap
    service/my-cluster-kafka-brokers
poddisruptionbudgets
    poddisruptionbudget.policy/my-cluster-kafka
roles
    role.rbac.authorization.k8s.io/my-cluster-entity-operator
rolebindings
    rolebinding.rbac.authorization.k8s.io/my-cluster-entity-topic-operator-role
    rolebinding.rbac.authorization.k8s.io/my-cluster-entity-user-operator-role
networkpolicies
    networkpolicy.networking.k8s.io/my-cluster-entity-operator
    networkpolicy.networking.k8s.io/my-cluster-network-policy-kafka
pods
    pod/my-cluster-broker-10
    pod/my-cluster-broker-11
    pod/my-cluster-broker-12
    pod/my-cluster-controller-0
    pod/my-cluster-controller-1
    pod/my-cluster-controller-2
    pod/my-cluster-entity-operator-bb7c65dd4-9zdmk
persistentvolumeclaims
    persistentvolumeclaim/data-my-cluster-broker-10
    persistentvolumeclaim/data-my-cluster-broker-11
    persistentvolumeclaim/data-my-cluster-broker-12
    persistentvolumeclaim/data-my-cluster-controller-0
    persistentvolumeclaim/data-my-cluster-controller-1
    persistentvolumeclaim/data-my-cluster-controller-2
ingresses
routes
clusterroles
    clusterrole.rbac.authorization.k8s.io/strimzi-cluster-operator-global
    clusterrole.rbac.authorization.k8s.io/strimzi-cluster-operator-leader-election
    clusterrole.rbac.authorization.k8s.io/strimzi-cluster-operator-namespaced
    clusterrole.rbac.authorization.k8s.io/strimzi-cluster-operator-watched
    clusterrole.rbac.authorization.k8s.io/strimzi-entity-operator
    clusterrole.rbac.authorization.k8s.io/strimzi-kafka-broker
    clusterrole.rbac.authorization.k8s.io/strimzi-kafka-client
clusterrolebindings
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-broker-delegation
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-client-delegation
clusteroperator
    deployment.apps/strimzi-cluster-operator
    replicaset.apps/strimzi-cluster-operator-6596f469c9
    pod/strimzi-cluster-operator-6596f469c9-smsw2
    configmap/strimzi-cluster-operator
draincleaner
customresources
    kafkanodepools.kafka.strimzi.io
        broker
        controller
    kafkas.kafka.strimzi.io
        my-cluster
    kafkatopics.kafka.strimzi.io
        my-topic
    strimzipodsets.core.strimzi.io
        my-cluster-broker
        my-cluster-controller
events
logs
    my-cluster-broker-10
    my-cluster-broker-11
    my-cluster-broker-12
    my-cluster-controller-0
    my-cluster-controller-1
    my-cluster-controller-2
    my-cluster-entity-operator-bb7c65dd4-9zdmk
Report file report-17-03-2025_12-26-05.zip created
```

When troubleshooting TLS issues, examining certificate details helps verify configuration and expiration dates.
For example, let's inspect the cluster CA certificate, which signs all server certificates.
While we can retrieve this using `kubectl`, this example demonstrates working with must-gather script output.
Use the command from session 002 to generate a fresh report from the current cluster.

```sh
$ unzip -p ~/Downloads/report-12-10-2024_11-31-59.zip reports/secrets/my-cluster-cluster-ca-cert.yaml \
  | yq '.data."ca.crt"' | base64 -d | openssl x509 -inform pem -noout -text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            26:9e:a1:7d:4d:34:cb:6b:ec:98:03:46:fb:7a:82:ad:68:80:bd:8e
        Signature Algorithm: sha512WithRSAEncryption
        Issuer: O=io.strimzi, CN=cluster-ca v0
        Validity
            Not Before: Sep  8 16:28:42 2022 GMT
            Not After : Sep  8 16:28:42 2023 GMT
        Subject: O=io.strimzi, CN=cluster-ca v0
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (4096 bit)
                Modulus:
                    ...
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Subject Key Identifier:
                2D:1D:63:F6:20:57:33:7D:59:73:DF:15:74:A2:A8:3D:E1:5B:3E:38
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
    Signature Algorithm: sha512WithRSAEncryption
    Signature Value:
        ...
```

If certificate inspection doesn't reveal the issue, add the `-Djavax.net.debug=ssl:handshake` Java option to the client for detailed handshake information.

## Getting Heap Dumps

It is possible to collect broker JVM heap dumps and other advanced diagnostic data such as thread dumps and flame graphs.

> [!WARNING]
> Taking a heap dump is a resource-intensive operation that can cause the Java application to pause temporarily.
> This is not recommended for production environments unless the memory issue cannot be reproduced in a test environment.

While debugging locally is often easier and faster, some issues only manifest in Kubernetes due to environment-specific factors like networking, resource limits, or interactions with other components.
Even when attempting to replicate the Kubernetes configuration locally, subtle differences in service discovery, security settings, or operator-managed configurations may result in different behavior.

Create an additional volume with the desired size using a PersistentVolumeClaim (PVC).

```sh
$ kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
EOF
persistentvolumeclaim/my-pvc created
```

Mount the new volume using the additional volume feature in the Kafka template. This triggers a rolling update.
The mount point must be under `/mnt`.

> [!WARNING]
> Adding a custom volume triggers pod restarts, which can make it difficult to capture issues that have already occurred.
> If the issue cannot be easily reproduced in a test environment, consider configuring the volume in advance to avoid disruptive pod restarts.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        template:
            pod:
              volumes:
                - name: my-volume
                  persistentVolumeClaim:
                    claimName: my-pvc
            kafkaContainer:
              volumeMounts:
                - name: my-volume
                  mountPath: "/mnt/data"'
kafka.kafka.strimzi.io/my-cluster patched
```

Once the rolling update completes, generate a broker heap dump and copy the output file to your local machine.

```sh
$ PID="$(kubectl exec my-cluster-broker-10 -- jcmd | grep "kafka.Kafka" | awk '{print $1}')"

$ kubectl exec my-cluster-broker-10 -- jcmd "$PID" VM.flags
724:
-XX:CICompilerCount=4 -XX:ConcGCThreads=3 -XX:G1ConcRefinementThreads=10 -XX:G1EagerReclaimRemSetThreshold=32 -XX:G1HeapRegionSize=4194304
-XX:GCDrainStackTargetSize=64 -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/mnt/data/oome.hprof -XX:InitialHeapSize=5368709120
-XX:+ManagementServer -XX:MarkStackSize=4194304 -XX:MaxHeapSize=5368709120 -XX:MaxNewSize=3221225472 -XX:MinHeapDeltaBytes=4194304
-XX:MinHeapSize=5368709120 -XX:NonNMethodCodeHeapSize=5839372 -XX:NonProfiledCodeHeapSize=122909434 -XX:ProfiledCodeHeapSize=122909434
-XX:ReservedCodeCacheSize=251658240 -XX:+SegmentedCodeCache -XX:SoftMaxHeapSize=5368709120 -XX:-THPStackMitigation
-XX:+UseCompressedClassPointers -XX:+UseCompressedOops -XX:+UseFastUnorderedTimeStamps -XX:+UseG1GC

$ kubectl exec my-cluster-broker-10 -- jcmd "$PID" GC.heap_dump /mnt/data/heap.hprof
724:
Dumping heap to /mnt/data/heap.hprof ...
Heap dump file created [179236580 bytes in 0.664 secs]

$ kubectl cp my-cluster-broker-10:/mnt/data/heap.hprof "$HOME"/Downloads/heap.hprof
tar: Removing leading `/' from member names
```

If the pod is crash looping, we can still recover the dump by creating a temporary pod and mounting the same volume.

```sh
$ kubectl run my-pod --restart "Never" --image "foo" --overrides "{
  \"spec\": {
    \"containers\": [
      {
        \"name\": \"busybox\",
        \"image\": \"busybox\",
        \"imagePullPolicy\": \"IfNotPresent\",
        \"command\": [\"/bin/sh\", \"-c\", \"trap : TERM INT; sleep infinity & wait\"],
        \"volumeMounts\": [
          {\"name\": \"data\", \"mountPath\": \"/mnt/data\"}
        ]
      }
    ],
    \"volumes\": [
      {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"my-pvc\"}}
    ]
  }
}"

$ kubectl exec my-pod -- ls -lh /mnt/data
total 171M   
-rw-------    1 1001     root      170.9M Mar 17 14:38 heap.hprof
```

We can analyze the heap dump using tools like Eclipse Memory Analyzer (MAT).
