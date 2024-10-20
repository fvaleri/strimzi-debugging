## Deploy a Kafka cluster on localhost

In this example, we deploy a Kafka cluster on localhost.
This is useful for quick tests where a multi node cluster is not required.
We use the latest upstream Kafka release because the downstream release is just a rebuild with few additional and optional plugins.

> [!NOTE]  
> The `init.sh` script is used to easily initialize or reset the test environment.
> It downloads Kafka to localhost and initializes the Kubernetes cluster installing the Cluster Operator.

```sh
$ source init.sh
Configuring Kafka on localhost
Downloading Kafka to /tmp/kafka-[version]
Configuring Strimzi on Kubernetes
namespace/test created
Downloading Strimzi to /tmp/strimzi-[version].yaml
Done

$ CLUSTER_ID="$($KAFKA_HOME/bin/kafka-storage.sh random-uuid)"; \
  "$KAFKA_HOME"/bin/kafka-storage.sh format -c "$KAFKA_HOME"/config/kraft/server.properties -t "$CLUSTER_ID" \
    && "$KAFKA_HOME"/bin/kafka-server-start.sh -daemon "$KAFKA_HOME"/config/kraft/server.properties
Formatting /tmp/kraft-combined-logs with metadata.version [version].

$ jcmd | grep kafka
1523381 kafka.Kafka /tmp/kafka-[version]/config/kraft/server.properties
```

We create a new topic with 3 partitions, then produce and consume some messages.
When consuming messages, you can print additional data such as the partition number.
Every consumer with the same `group.id` is part of the same consumer group.

```sh
$ "$KAFKA_HOME"/bin/kafka-topics.sh --bootstrap-server :9092 --create --topic my-topic --partitions 3 --replication-factor 1 
Created topic my-topic.

$ $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server :9092 --topic my-topic --describe
Topic: my-topic	TopicId: wBAzSO5tTkOp71nsve_U_w	PartitionCount: 3	ReplicationFactor: 1	Configs: segment.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 1	Isr: 1	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1	Isr: 1	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 2	Leader: 1	Replicas: 1	Isr: 1	Elr: 	LastKnownElr:

$ "$KAFKA_HOME"/bin/kafka-console-producer.sh --bootstrap-server :9092 --topic my-topic --property parse.key=true --property key.separator="#"
>32947#hello
>24910#kafka
>45237#world
>^C

$ "$KAFKA_HOME"/bin/kafka-console-consumer.sh --bootstrap-server :9092 --topic my-topic --group my-group --from-beginning \
  --max-messages 3 --property print.partition=true --property print.key=true
Partition:0	24910	kafka
Partition:2	32947	hello
Partition:2	45237	world
Processed a total of 3 messages
```

It works, but where these messages are being stored?
The broker property `log.dirs` configures where our topic partitions are stored.
We have 3 partitions, which corresponds to exactly 3 folders on disk.

```sh
$ cat $KAFKA_HOME/config/kraft/server.properties | grep log.dirs
log.dirs=/tmp/kraft-combined-logs

$ ls -lh /tmp/kraft-combined-logs | grep my-topic
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  5 13:45 my-topic-0
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  5 13:45 my-topic-1
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  5 13:45 my-topic-2
```

The consumer output shows that messages were sent to partition 0 and 2.
Looking inside partition 0, we have a `.log` file containing our records (each segment is named after the initial offset), an `.index` file mapping the record offset to its position in the log and a `.timeindex` file mapping the record timestamp to its position in the log.
The other two files contain additional metadata.

```sh
$ ls -lh /tmp/kraft-combined-logs/my-topic-0
total 12K
-rw-r--r--. 1 fvaleri fvaleri 10M Sep  5 13:45 00000000000000000000.index
-rw-r--r--. 1 fvaleri fvaleri  78 Sep  5 13:45 00000000000000000000.log
-rw-r--r--. 1 fvaleri fvaleri 10M Sep  5 13:45 00000000000000000000.timeindex
-rw-r--r--. 1 fvaleri fvaleri   8 Sep  5 13:45 leader-epoch-checkpoint
-rw-r--r--. 1 fvaleri fvaleri  43 Sep  5 13:45 partition.metadata
```

Partition log files are in binary format, but Kafka includes a dump tool for decoding them.
On this partition, we have one batch (`baseOffset`), containing only one record (`| offset`) with key "24910" and payload "kafka".

```sh
$ $KAFKA_HOME/bin/kafka-dump-log.sh --deep-iteration --print-data-log --files /tmp/kraft-combined-logs/my-topic-0/00000000000000000000.log
Dumping /tmp/kraft-combined-logs/my-topic-0/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 20 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1725536752604 size: 78 magic: 2 compresscodec: none crc: 4051670483 isvalid: true
| offset: 0 CreateTime: 1725536752604 keySize: 5 valueSize: 5 sequence: 0 headerKeys: [] key: 24910 payload: kafka
```

Our consumer group should have committed the offsets to the `__consumer_offsets` internal topic.
The problem is that this topic has 50 partitions by default, so how do we know which partition was used? 
We can use the same algorithm that Kafka uses to map a `group.id` to a specific offset coordinating partition.
The `kafka-cp` function is defined inside the `init.sh` script.

```sh
$ kafka-cp my-group
12
```

We know that the consumer group commit record was sent to `__consumer_offsets-12`, so let's dump this partition too.
Here values are encoded for performance reasons, so we have to pass the `--offsets-decoder` option.

This partition contains other metadata, but we are specifically interested in the `offset_commit` key.
We have a batch from our consumer group, which includes 3 records, one for each input topic partition.
As expected, the consumer group committed offset1@partition0, offset2@partition2, and offset0@partition1 (this didn't received any message).

```sh
$ $KAFKA_HOME/bin/kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder --files /tmp/kraft-combined-logs/__consumer_offsets-12/00000000000000000000.log
Dumping /tmp/kraft-combined-logs/__consumer_offsets-12/00000000000000000000.log
Log starting offset: 0
...
baseOffset: 90 lastOffset: 92 count: 3 baseSequence: 0 lastSequence: 2 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 9544 CreateTime: 1725536760740 size: 232 magic: 2 compresscodec: none crc: 1509164452 isvalid: true
| offset: 90 CreateTime: 1725536760740 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":0}} payload: {"version":"3","data":{"offset":1,"leaderEpoch":0,"metadata":"","commitTimestamp":1725536760740}}
| offset: 91 CreateTime: 1725536760740 keySize: 26 valueSize: 24 sequence: 1 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":1}} payload: {"version":"3","data":{"offset":0,"leaderEpoch":-1,"metadata":"","commitTimestamp":1725536760740}}
| offset: 92 CreateTime: 1725536760740 keySize: 26 valueSize: 24 sequence: 2 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":2}} payload: {"version":"3","data":{"offset":2,"leaderEpoch":0,"metadata":"","commitTimestamp":1725536760740}}
...
```

## Deploy a Kafka cluster on Kubernetes

In this example, we deploy a Kafka cluster to a Kubernetes cluster using the operator.

> [!IMPORTANT]  
> Login first if your Kubernetes cluster requires authentication.

```sh
$ source init.sh
Configuring Kafka on localhost
Configuring Strimzi on Kubernetes
namespace/test created
Done
```

Then, we create a new Kafka cluster and test topic.
In the YAML files, we can see how the desired cluster state is declared.

In addition to Kafka pods, the Entity Operator (EO) pod is also deployed, which includes two namespaced operators: the Topic Operator (TO), which reconciles topic resources, and the User Operator (UO), which reconciles user resources.
If you want to deploy multiple Kafka clusters on the same namespace, make sure to have only one instance of these operators to avoid race conditions.

```sh
$ kubectl create -f sessions/001/install
kafkanodepool.kafka.strimzi.io/controller created
kafkanodepool.kafka.strimzi.io/broker created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get sps,knp,k,kt,po
NAME                                                  PODS   READY PODS   CURRENT PODS   AGE
strimzipodset.core.strimzi.io/my-cluster-broker       3      3            3              60s
strimzipodset.core.strimzi.io/my-cluster-controller   3      3            3              60s

NAME                                        DESIRED REPLICAS   ROLES            NODEIDS
kafkanodepool.kafka.strimzi.io/broker       3                  ["broker"]       [7,8,9]
kafkanodepool.kafka.strimzi.io/controller   3                  ["controller"]   [0,1,2]

NAME                                DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   METADATA STATE   WARNINGS
kafka.kafka.strimzi.io/my-cluster                                                  True    KRaft            

NAME                                   CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/my-topic   my-cluster   3            3                    True

NAME                                             READY   STATUS    RESTARTS   AGE
pod/my-cluster-broker-7                          1/1     Running   0          59s
pod/my-cluster-broker-8                          1/1     Running   0          59s
pod/my-cluster-broker-9                          1/1     Running   0          59s
pod/my-cluster-controller-0                      1/1     Running   0          59s
pod/my-cluster-controller-1                      1/1     Running   0          59s
pod/my-cluster-controller-2                      1/1     Running   0          59s
pod/my-cluster-entity-operator-5bfb48dbc-6fjl9   2/2     Running   0          26s
pod/strimzi-cluster-operator-7fb8ff4bd-4ds5g     1/1     Running   0          82s
```

When the Kafka cluster is ready, we produce and consume some messages.
We are using a simple function defined in `init.sh` to spin up a pod for invoking Kafka tools.
You can also use the broker pods for that, but it is always risky to spin up another JVM inside a pod, especially in production.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
>hello
>kafka
>world
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --group my-group --from-beginning --max-messages 3
hello
kafka
world
Processed a total of 3 messages
```

When debugging issues, you usually need to retrieve various artifacts from the environment, which can be a lot of effort.
Fortunately, Strimzi maintains a backward compatible must-gather script that can be used to download all relevant artifacts and logs from a specific Kafka cluster.
Add the `--secrets=all` option to also get secret values.

```sh
$ curl -s https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/tools/report.sh \
  | bash -s -- --namespace=test --cluster=my-cluster --out-dir=~/Downloads
deployments
    deployment.apps/my-cluster-entity-operator
statefulsets
replicasets
    replicaset.apps/my-cluster-entity-operator-57c4d54c94
configmaps
    configmap/my-cluster-broker-7
    configmap/my-cluster-broker-8
    configmap/my-cluster-broker-9
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
    pod/my-cluster-broker-7  
    pod/my-cluster-broker-8  
    pod/my-cluster-broker-9  
    pod/my-cluster-controller-0
    pod/my-cluster-controller-1
    pod/my-cluster-controller-2
    pod/my-cluster-entity-operator-57c4d54c94-m87qg
persistentvolumeclaims
    persistentvolumeclaim/data-my-cluster-broker-7
    persistentvolumeclaim/data-my-cluster-broker-8
    persistentvolumeclaim/data-my-cluster-broker-9
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
    replicaset.apps/strimzi-cluster-operator-7fb8ff4bd
    pod/strimzi-cluster-operator-7fb8ff4bd-vf4zl
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
    my-cluster-broker-7
    my-cluster-broker-8
    my-cluster-broker-9
    my-cluster-controller-0
    my-cluster-controller-1
    my-cluster-controller-2
    my-cluster-entity-operator-57c4d54c94-m87qg
Report file report-12-10-2024_11-31-59.zip created
```
