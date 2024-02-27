## Kafka introduction and deployments

[Apache Kafka](https://kafka.apache.org) is a distributed streaming platform that lets you read, write, store, and process messages across many machines.
The [CNCF Strimzi](https://strimzi.io) project includes a set of operators, which help in deploying and manging Kafka clusters on Kubernetes.
Not every use case justifies the additional complexity that Kafka brings to the table.
It is best suited when you have a high throughput of relatively small messages that traditional message brokers struggle to manage, or you have near realtime stream processing requirements.

Kafka provides two main layers that can scale independently: the storage layer, which stores messages efficiently in a cluster of brokers, and the compute layer which is built on top of the producer and consumer APIs.
There are also two higher level APIs: the connect API for integration with external systems and the streams API for stream processing.
Within a cluster, the control plane handles cluster metadata and the data plane handles user data.
A broker in a cluster is elected as controller, which has the additional responsibility of managing the states of data partitions and replicas and for performing administrative tasks like reassigning partitions.
In ZooKeeper mode there is only one elected controller, while in the new KRaft mode we have a quorum of controllers. One broker is active at any time, while the others are ready to take over in case of failure.

<p align="center"><img src="images/cluster.png" height=250/></p>

Kafka uses a binary communication protocol over TCP (KRPC).
The protocol defines APIs as request/response message pairs and includes both the message format and error codes.
Clients send messages in the exact same binary format that brokers write to disk.
The protocol is backwards and forwards compatible, however there can be issues in case of message format changes.
This hasn't happened for a long time, but there is no guarantee.
Typically, every client opens N+1 connections, where N is the number of brokers in the cluster and 1 connection is for metadata updates.
Client requests are processed in the same order they are sent.

Each message is modeled as a record with timestamp, key, value, and optional headers.
Key and value are just byte arrays, which gives you the flexibility to encode the data in whatever format you want using your favorite serializer.
The timestamp is always present, but it can be set by the application when it sends (default), or by the Kafka runtime when it receives.
Whenever possible, records are buffered and sent in batches (a single request can include multiple batches, one for each partition).

Messages are stored in a topic, which is further divided into one or more partitions, distributed evenly across the brokers.
Each partition is stored on disk as a series of fixed-size commit logs called segments.
Each record within a partition has a unique id called the offset, which is a monotonically increasing number that is never reused.
Message ordering is only guaranteed at the partition level.
If this is a requirement, you can create a single-partition topic or use the same key for sending all related events, so that they always land in the same partition.
Beware that increasing topic partitions may break ordering.

The partition replication protocol is fundamental to Kafka.
By default, when a new batch of records arrives, it is firstly written into the Operating System's page cache, and only flushed to disk asynchronously.
If the Kafka JVM crashes for whatever reason, recent messages are still in the page cache, and will be flushed by the Operating System.
However, this doesn't protect from data loss when the machine crashes.
This is why enabling topic replication is important: having multiple replicas means data loss is only possible if multiple brokers can crash simultaneously.
To further improve fault tolerance, a rack-aware Kafka cluster can be used to distribute topic replicas evenly across data centers in the same geographic region.

<p align="center"><img src="images/replicas.png" height=450/></p>

One of the partition replicas is elected as the leader that gets all messages from producers, while the others are followers and can be read by consumers.
If you set a topic replication factor of N, the system can tolerate N-1 broker failures.
The last committed offset of a partition is called the high watermark (HW).

When sending messages, a producer with `acks=all` configuration (now default) will not get a send acknowledgement until all `min.insync.replicas` (ISR) have replicated the message.
At any time, the ISR only includes replicas that are up to date.
Multiple consumers with the same `group.id` form a consumer group and partitions are distributed among them using a partition assignor (that makes use of parallelism).
Within a consumer group, a partition is assigned to exactly one consumer to not break ordering, but that consumer can handle multiple partitions.
Each consumer periodically or manually commits its position (the next offsets to read) to an internal topic called `__consumer_offsets`.

<br/>

---
### Example: deploy a Kafka cluster on localhost

In this example, we deploy a Kafka cluster on localhost.
This is useful for quick tests where a multi node cluster is not required.
We use the latest upstream Kafka release because the downstream release is just a rebuild with few additional and optional plugins.

The `init.sh` script can be used to easily initialize or reset the test environment.
It downloads Kafka to localhost and initializes the Kubernetes cluster installing the Cluster Operator.

```sh
$ source init.sh
Downloading Kafka to /tmp/kafka-test
Done
Configuring Kafka on Kubernetes
namespace/test created
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
Topic: my-topic	TopicId: a4Lnw1iQSW6MALg0gvxZNQ	PartitionCount: 3	ReplicationFactor: 1	Configs: segment.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: my-topic	Partition: 1	Leader: 0	Replicas: 0	Isr: 0
	Topic: my-topic	Partition: 2	Leader: 0	Replicas: 0	Isr: 0

$ $KAFKA_HOME/bin/kafka-console-producer.sh --bootstrap-server :9092 --topic my-topic --property parse.key=true --property key.separator="#"
>1#hello
>2#world
>^C

$ $KAFKA_HOME/bin/kafka-console-consumer.sh --bootstrap-server :9092 --topic my-topic --group my-group --from-beginning \
  --property print.partition=true --property print.key=true
Partition:0	1	hello
Partition:2	2	world
^CProcessed a total of 2 messages
```

It works, but where these messages are being stored?
The broker property `log.dirs` configures where our topic partitions are stored.
We have 3 partitions, which corresponds to exactly 3 folders on disk.

```sh
$ cat $KAFKA_HOME/config/server.properties | grep log.dirs
log.dirs=/tmp/kafka-logs

$ ls -lh /tmp/kafka-logs/ | grep my-topic
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  8 16:55 my-topic-0
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  8 16:55 my-topic-1
drwxr-xr-x. 2 fvaleri fvaleri  140 Sep  8 16:55 my-topic-2
```

The consumer output shows that messages were sent to partition 0 and 2.
Looking inside partition 0, we have a `.log` file containing our records (each segment is named after the initial offset), an `.index` file mapping the record offset to its position in the log and a `.timeindex` file mapping the record timestamp to its position in the log.
The other two files contain additional metadata.

```sh
$ ls -lh /tmp/kafka-logs/my-topic-0/
total 12K
-rw-r--r--. 1 fvaleri fvaleri 10M Sep  8 16:55 00000000000000000000.index
-rw-r--r--. 1 fvaleri fvaleri  74 Sep  8 16:57 00000000000000000000.log
-rw-r--r--. 1 fvaleri fvaleri 10M Sep  8 16:55 00000000000000000000.timeindex
-rw-r--r--. 1 fvaleri fvaleri   8 Sep  8 16:55 leader-epoch-checkpoint
-rw-r--r--. 1 fvaleri fvaleri  43 Sep  8 16:55 partition.metadata
```

Partition log files are in binary format, but Kafka includes a dump tool for decoding them.
On this partition, we have one batch (`baseOffset`), containing only one record (`| offset`) with key "1" and value "hello".

```sh
$ $KAFKA_HOME/bin/kafka-dump-log.sh --deep-iteration --print-data-log --files /tmp/kafka-logs/my-topic-0/00000000000000000000.log
Dumping /tmp/kafka-logs/my-topic-0/00000000000000000000.log
Starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1662649069768 size: 74 magic: 2 compresscodec: none crc: 3775885203 isvalid: true
| offset: 0 CreateTime: 1662649069768 keySize: 1 valueSize: 5 sequence: 0 headerKeys: [] key: 1 payload: hello
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
Starting offset: 0
...
baseOffset: 15 lastOffset: 17 count: 3 baseSequence: 0 lastSequence: 2 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 1716 CreateTime: 1662649581270 size: 232 magic: 2 compresscodec: none crc: 4177101314 isvalid: true
| offset: 15 CreateTime: 1662649581270 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-0 payload: offset=1
| offset: 16 CreateTime: 1662649581270 keySize: 26 valueSize: 24 sequence: 1 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-1 payload: offset=0
| offset: 17 CreateTime: 1662649581270 keySize: 26 valueSize: 24 sequence: 2 headerKeys: [] key: offset_commit::group=my-group,partition=my-topic-2 payload: offset=1
```

<br/>

---
### Example: deploy a Kafka cluster on Kubernetes

In this example, we deploy a Kafka cluster to a Kubernetes cluster using the operator.

**Login first if you are running on OpenShift or authentication is required.**

```sh
$ source init.sh
Reusing Kafka in /tmp/kafka-test
Done
Configuring Kafka on Kubernetes
namespace/test created
Done
```

Then, we create a new Kafka cluster and test topic.
In the YAML files, we can see how the desired cluster state is declared.

In addition to ZooKeeper and Kafka pods, the Entity Operator (EO) pod is also deployed, which includes two namespaced operators: the Topic Operator (TO), which reconciles topic resources, and the User Operator (UO), which reconciles user resources.
If you want to deploy multiple Kafka clusters on the same namespace, make sure to have only one instance of these operators to avoid race conditions.

```sh
$ kubectl create -f sessions/001/resources
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get k,kt,po
NAME                                DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   WARNINGS
kafka.kafka.strimzi.io/my-cluster   3                        3                     True    

NAME                                                                                                                           CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/consumer-offsets---84e7a678d08f4bd226872e5cdd4eb527fadc1c6a                                        my-cluster   50           3                    True
kafkatopic.kafka.strimzi.io/my-topic                                                                                           my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/strimzi-store-topic---effb8e3e057afce1ecf67c3f5d8e4e3ff177fc55                                     my-cluster   1            3                    True
kafkatopic.kafka.strimzi.io/strimzi-topic-operator-kstreams-topic-store-changelog---b75e702040b99be8a9263134de3507fc0cc4017b   my-cluster   1            3                    True

NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-entity-operator-6d4d7b6fff-d2x7z   3/3     Running   0          83s
my-cluster-kafka-0                            1/1     Running   0          2m45s
my-cluster-kafka-1                            1/1     Running   0          2m45s
my-cluster-kafka-2                            1/1     Running   0          2m45s
my-cluster-zookeeper-0                        1/1     Running   0          4m7s
my-cluster-zookeeper-1                        1/1     Running   0          4m7s
my-cluster-zookeeper-2                        1/1     Running   0          4m7s
strimzi-cluster-operator-7b6bfcc96c-srsdt     1/1     Running   0          8m5s
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
world
hello
^CProcessed a total of 2 messages
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
    replicaset.apps/my-cluster-entity-operator-7d576599c5
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
    pod/my-cluster-entity-operator-7d576599c5-9q22j
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
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-broker-delegation
    clusterrolebinding.rbac.authorization.k8s.io/strimzi-cluster-operator-kafka-client-delegation
clusteroperator
    deployment.apps/strimzi-cluster-operator
    replicaset.apps/strimzi-cluster-operator-85b9b646cc
replicaset.apps/strimzi-cluster-operator-86948f6756
    pod/strimzi-cluster-operator-85b9b646cc-dvjfh
    configmap/strimzi-cluster-operator
draincleaner
customresources
    kafkas.kafka.strimzi.io
        my-cluster
    kafkatopics.kafka.strimzi.io
        consumer-offsets---84e7a678d08f4bd226872e5cdd4eb527fadc1c6a
        my-topic
        strimzi-store-topic---effb8e3e057afce1ecf67c3f5d8e4e3ff177fc55
        strimzi-topic-operator-kstreams-topic-store-changelog---b75e702040b99be8a9263134de3507fc0cc4017b
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
    my-cluster-entity-operator-7d576599c5-9q22j
Report file report-21-02-2024_15-11-18.zip created
```
