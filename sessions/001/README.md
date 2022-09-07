## Deploy a Kafka cluster on localhost

In this example, we deploy a Kafka cluster on localhost.
This is useful for quick tests where a multi node cluster is not required.
We use the latest upstream Kafka release because the downstream release is just a rebuild with few additional and optional plugins.

The `init.sh` script can be used to easily initialize or reset the test environment.
It downloads Kafka to localhost and initializes the Kubernetes cluster installing the Cluster Operator.

```sh
$ source init.sh
Configuring Kafka on localhost
Downloading Kafka to /tmp/kafka-v
Configuring Strimzi on Kubernetes
namespace/test created
Downloading Strimzi to /tmp/strimzi-v.yaml
Done

$ $KAFKA_HOME/bin/zookeeper-server-start.sh -daemon $KAFKA_HOME/config/zookeeper.properties \
  && sleep 5 && $KAFKA_HOME/bin/kafka-server-start.sh -daemon $KAFKA_HOME/config/server.properties

$ jcmd | grep kafka
831273 org.apache.zookeeper.server.quorum.QuorumPeerMain /tmp/kafka.yidQitI/config/zookeeper.properties
831635 kafka.Kafka /tmp/kafka.yidQitI/config/server.properties
```

We create a new topic with 3 partitions, then produce and consume some messages.
When consuming messages, you can print additional data such as the partition number.
Every consumer with the same `group.id` is part of the same consumer group.

```sh
$ $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server :9092 --topic my-topic --create --partitions 3 --replication-factor 1 
Created topic my-topic.

$ $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server :9092 --topic my-topic --describe
Topic: my-topic	TopicId: _sLsPUT-RcSuLdv9niI2ig	PartitionCount: 3	ReplicationFactor: 1	Configs: 
	Topic: my-topic	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: my-topic	Partition: 1	Leader: 0	Replicas: 0	Isr: 0
	Topic: my-topic	Partition: 2	Leader: 0	Replicas: 0	Isr: 0

$ $KAFKA_HOME/bin/kafka-console-producer.sh --bootstrap-server :9092 --topic my-topic --property parse.key=true --property key.separator="#"
>1#hello
>2#world
>^C

$ $KAFKA_HOME/bin/kafka-console-consumer.sh --bootstrap-server :9092 --topic my-topic --group my-group --from-beginning \
  --max-messages 2 --property print.partition=true --property print.key=true
Partition:0	1	hello
Partition:2	2	world
Processed a total of 2 messages
```

It works, but where these messages are being stored?
The broker property `log.dirs` configures where our topic partitions are stored.
We have 3 partitions, which corresponds to exactly 3 folders on disk.

```sh
$ cat $KAFKA_HOME/config/server.properties | grep log.dirs
log.dirs=/tmp/kafka-logs

$ ls -lh /tmp/kafka-logs/ | grep my-topic
drwxr-xr-x. 2 fvaleri fvaleri  140 Jul  4 17:51 my-topic-0
drwxr-xr-x. 2 fvaleri fvaleri  140 Jul  4 17:51 my-topic-1
drwxr-xr-x. 2 fvaleri fvaleri  140 Jul  4 17:51 my-topic-2
```

The consumer output shows that messages were sent to partition 0 and 2.
Looking inside partition 0, we have a `.log` file containing our records (each segment is named after the initial offset), an `.index` file mapping the record offset to its position in the log and a `.timeindex` file mapping the record timestamp to its position in the log.
The other two files contain additional metadata.

```sh
$ ls -lh /tmp/kafka-logs/my-topic-0
total 12K
-rw-r--r--. 1 fvaleri fvaleri 10M Jul  4 17:51 00000000000000000000.index
-rw-r--r--. 1 fvaleri fvaleri  74 Jul  4 17:51 00000000000000000000.log
-rw-r--r--. 1 fvaleri fvaleri 10M Jul  4 17:51 00000000000000000000.timeindex
-rw-r--r--. 1 fvaleri fvaleri   8 Jul  4 17:51 leader-epoch-checkpoint
-rw-r--r--. 1 fvaleri fvaleri  43 Jul  4 17:51 partition.metadata
```

Partition log files are in binary format, but Kafka includes a dump tool for decoding them.
On this partition, we have one batch (`baseOffset`), containing only one record (`| offset`) with key "1" and value "hello".

```sh
$ $KAFKA_HOME/bin/kafka-dump-log.sh --deep-iteration --print-data-log --files /tmp/kafka-logs/my-topic-0/00000000000000000000.log
Dumping /tmp/kafka-logs/my-topic-0/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1720108310684 size: 74 magic: 2 compresscodec: none crc: 990125471 isvalid: true
| offset: 0 CreateTime: 1720108310684 keySize: 1 valueSize: 5 sequence: 0 headerKeys: [] key: 1 payload: hello
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
As expected, the consumer group committed offset1 on partition0 and partition2, plus offset0 on partition1 (we sent 2 messages).

```sh
$ $KAFKA_HOME/bin/kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder \
  --files /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Dumping /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Log starting offset: 0
...
baseOffset: 1 lastOffset: 3 count: 3 baseSequence: 0 lastSequence: 2 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 345 CreateTime: 1720108358031 size: 232 magic: 2 compresscodec: none crc: 432303170 isvalid: true
| offset: 1 CreateTime: 1720108358031 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-0 payload: offset=1
| offset: 2 CreateTime: 1720108358031 keySize: 26 valueSize: 24 sequence: 1 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-1 payload: offset=0
| offset: 3 CreateTime: 1720108358031 keySize: 26 valueSize: 24 sequence: 2 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-2 payload: offset=1
...
```

## Deploy a Kafka cluster on Kubernetes

In this example, we deploy a Kafka cluster to a Kubernetes cluster using the operator.

**Login first if your Kubernetes cluster requires authentication.**

```sh
$ source init.sh
Configuring Kafka on localhost
Configuring Strimzi on Kubernetes
namespace/test created
Done
```

Then, we create a new Kafka cluster and test topic.
In the YAML files, we can see how the desired cluster state is declared.

In addition to ZooKeeper and Kafka pods, the Entity Operator (EO) pod is also deployed, which includes two namespaced operators: the Topic Operator (TO), which reconciles topic resources, and the User Operator (UO), which reconciles user resources.
If you want to deploy multiple Kafka clusters on the same namespace, make sure to have only one instance of these operators to avoid race conditions.

```sh
$ kubectl create -f sessions/001/resources
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic create

$ kubectl get sps,knp,k,kt,po
NAME                                                 PODS   READY PODS   CURRENT PODS   AGE
strimzipodset.core.strimzi.io/my-cluster-kafka       3      3            3              2m2s
strimzipodset.core.strimzi.io/my-cluster-zookeeper   3      3            3              2m31s

NAME                                   DESIRED REPLICAS   ROLES        NODEIDS
kafkanodepool.kafka.strimzi.io/kafka   3                  ["broker"]   [0,1,2]

NAME                                DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   METADATA STATE   WARNINGS
kafka.kafka.strimzi.io/my-cluster                            3                     True    ZooKeeper        

NAME                                   CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/my-topic   my-cluster   3            3                    True

NAME                                             READY   STATUS    RESTARTS   AGE
pod/my-cluster-entity-operator-d4b4d8c8c-z29xq   2/2     Running   0          99s
pod/my-cluster-kafka-0                           1/1     Running   0          2m2s
pod/my-cluster-kafka-1                           1/1     Running   0          2m2s
pod/my-cluster-kafka-2                           1/1     Running   0          2m2s
pod/my-cluster-zookeeper-0                       1/1     Running   0          2m30s
pod/my-cluster-zookeeper-1                       1/1     Running   0          2m30s
pod/my-cluster-zookeeper-2                       1/1     Running   0          2m30s
pod/strimzi-cluster-operator-6865489846-qskht    1/1     Running   0          2m50s
```

When the Kafka cluster is ready, we produce and consume some messages.
Note that we are using a nice function to avoid repeating that for every client we need.
You can also use the broker pods for that, but it is always risky to spin up another JVM inside a pod, especially in production.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
>hello
>world
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --group my-group --from-beginning --max-messages 2
hello
world
Processed a total of 2 messages
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
    replicaset.apps/my-cluster-entity-operator-d4b4d8c8c
configmaps
    configmap/my-cluster-entity-topic-operator-config
    configmap/my-cluster-entity-user-operator-config
    configmap/my-cluster-kafka-0
    configmap/my-cluster-kafka-1
    configmap/my-cluster-kafka-2
    configmap/my-cluster-zookeeper-config
secrets
    secret/my-cluster-clients-ca
    secret/my-cluster-clients-ca-cert
    secret/my-cluster-cluster-ca
    secret/my-cluster-cluster-ca-cert
    secret/my-cluster-cluster-operator-certs
    secret/my-cluster-entity-topic-operator-certs
    secret/my-cluster-entity-user-operator-certs
    secret/my-cluster-kafka-brokers
    secret/my-cluster-zookeeper-nodes
services
    service/my-cluster-kafka-bootstrap
    service/my-cluster-kafka-brokers
    service/my-cluster-zookeeper-client
    service/my-cluster-zookeeper-nodes
poddisruptionbudgets
    poddisruptionbudget.policy/my-cluster-kafka
    poddisruptionbudget.policy/my-cluster-zookeeper
roles
    role.rbac.authorization.k8s.io/my-cluster-entity-operator
rolebindings
    rolebinding.rbac.authorization.k8s.io/my-cluster-entity-topic-operator-role
    rolebinding.rbac.authorization.k8s.io/my-cluster-entity-user-operator-role
networkpolicies
    networkpolicy.networking.k8s.io/my-cluster-entity-operator
    networkpolicy.networking.k8s.io/my-cluster-network-policy-kafka
    networkpolicy.networking.k8s.io/my-cluster-network-policy-zookeeper
pods
    pod/my-cluster-entity-operator-d4b4d8c8c-z29xq
    pod/my-cluster-kafka-0
    pod/my-cluster-kafka-1
    pod/my-cluster-kafka-2
    pod/my-cluster-zookeeper-0
    pod/my-cluster-zookeeper-1
    pod/my-cluster-zookeeper-2
persistentvolumeclaims
    persistentvolumeclaim/data-my-cluster-kafka-0
    persistentvolumeclaim/data-my-cluster-kafka-1
    persistentvolumeclaim/data-my-cluster-kafka-2
    persistentvolumeclaim/data-my-cluster-zookeeper-0
    persistentvolumeclaim/data-my-cluster-zookeeper-1
    persistentvolumeclaim/data-my-cluster-zookeeper-2
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
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-all-ns
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-entity-operator-delegation-all-ns
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-broker-delegation
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-client-delegation
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-leader-election-all-ns
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-watched-all-ns
clusteroperator
    deployment.apps/strimzi-cluster-operator
    replicaset.apps/strimzi-cluster-operator-6865489846
    pod/strimzi-cluster-operator-6865489846-qskht
    configmap/strimzi-cluster-operator
draincleaner
customresources
    kafkanodepools.kafka.strimzi.io
        kafka
    kafkas.kafka.strimzi.io
        my-cluster
    kafkatopics.kafka.strimzi.io
        my-topic
    strimzipodsets.core.strimzi.io
        my-cluster-kafka
        my-cluster-zookeeper
events
logs
    my-cluster-kafka-0
    my-cluster-kafka-1
    my-cluster-kafka-2
    my-cluster-zookeeper-0
    my-cluster-zookeeper-1
    my-cluster-zookeeper-2
    my-cluster-entity-operator-d4b4d8c8c-z29xq
Report file report-04-07-2024_18-40-30.zip created
```
