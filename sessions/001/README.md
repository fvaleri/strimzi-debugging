## Deploying a Kafka Cluster

This session demonstrates how to deploy a Kafka cluster to Kubernetes using the Strimzi operator.
We can use the `init.sh` script to initialize or reset your test environment easily.

> [!IMPORTANT]  
> Login first if your Kubernetes cluster requires authentication.

```sh
$ source init.sh
Creating namespace test
Installing Strimzi x.x.x
```

Next, create a new Kafka cluster and test topic.
The YAML files demonstrate how to declare the desired cluster state.

In addition to the Kafka pods, the deployment includes an Entity Operator (EO) pod, which contains two namespaced operators: the Topic Operator (TO) and the User Operator (UO).
These operators are designed to manage a single namespace and a single Kafka cluster.

```sh
$ kubectl create -f sessions/001/install.yaml
kafkanodepool.kafka.strimzi.io/controller created
kafkanodepool.kafka.strimzi.io/broker created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get sps,knp,k,kt,po
NAME                                                  PODS   READY PODS   CURRENT PODS   AGE
strimzipodset.core.strimzi.io/my-cluster-broker       3      3            3              35m
strimzipodset.core.strimzi.io/my-cluster-controller   3      3            3              35m

NAME                                        DESIRED REPLICAS   ROLES            NODEIDS
kafkanodepool.kafka.strimzi.io/broker       3                  ["broker"]       [10,11,12]
kafkanodepool.kafka.strimzi.io/controller   3                  ["controller"]   [0,1,2]

NAME                                READY   WARNINGS   KAFKA VERSION   METADATA VERSION
kafka.kafka.strimzi.io/my-cluster   True               4.2.0           4.2-IV1

NAME                                   CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/my-topic   my-cluster   3            3                    True

NAME                                             READY   STATUS    RESTARTS   AGE
pod/my-cluster-broker-10                         1/1     Running   0          35m
pod/my-cluster-broker-11                         1/1     Running   0          35m
pod/my-cluster-broker-12                         1/1     Running   0          35m
pod/my-cluster-controller-0                      1/1     Running   0          35m
pod/my-cluster-controller-1                      1/1     Running   0          35m
pod/my-cluster-controller-2                      1/1     Running   0          35m
pod/my-cluster-entity-operator-bdd594cf7-54jcs   2/2     Running   0          34m
pod/strimzi-cluster-operator-644f44d6d8-585v5    1/1     Running   0          24m
```

Once the Kafka cluster is ready, we can try to send and receive messages.
The operator creates a normal service for the initial connection (bootstrap) and a headless service to give each broker pod a stable DNS name.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic \
  --reader-property parse.key=true --reader-property key.separator="#"
>32947#hello
>24910#kafka
>45237#world
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic \
  --group my-group --from-beginning --max-messages 3 --formatter-property print.partition=true --formatter-property print.key=true
Partition:0	24910	kafka
Partition:2	32947	hello
Partition:2	45237	world
Processed a total of 3 messages
```

Now that message production and consumption are working, let's explore where the messages are actually stored.
The broker property `log.dirs` specifies the location where topic partitions are stored on disk.
With 3 partitions, you'll find exactly 3 corresponding directories.

```sh
$ kubectl exec my-cluster-broker-10 -- cat /tmp/strimzi.properties | grep log.dirs
log.dirs=/var/lib/kafka/data/kafka-log10

$ kubectl exec my-cluster-broker-10 -- ls -lh /var/lib/kafka/data/kafka-log10 | grep my-topic
drwxr-xr-x. 2 kafka root  167 Mar 23 13:18 my-topic-0
drwxr-xr-x. 2 kafka root  167 Mar 23 13:15 my-topic-1
drwxr-xr-x. 2 kafka root  167 Mar 23 13:18 my-topic-2
```

The consumer output indicates that messages were sent to partitions 0 and 2.
Inside partition 0, you'll find several files: a `.log` file containing the records (segments are named by their initial offset), an `.index` file that maps record offsets to their log positions, and a `.timeindex` file that maps record timestamps to their log positions.
The remaining two files store additional partition metadata.

```sh
$ kubectl exec my-cluster-broker-10 -- ls -lh /var/lib/kafka/data/kafka-log10/my-topic-0
total 12K
-rw-r--r--. 1 kafka root 10M Mar 23 13:15 00000000000000000000.index
-rw-r--r--. 1 kafka root  78 Mar 23 13:18 00000000000000000000.log
-rw-r--r--. 1 kafka root 10M Mar 23 13:15 00000000000000000000.timeindex
-rw-r--r--. 1 kafka root   8 Mar 23 13:18 leader-epoch-checkpoint
-rw-r--r--. 1 kafka root  43 Mar 23 13:15 partition.metadata
```

Partition log files use a binary format, but Kafka provides a dump tool to decode and inspect them.
In this partition, there's one batch (`baseOffset`) containing a single record (`| offset`) with key "24910" and payload "kafka".

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log \
  --files /var/lib/kafka/data/kafka-log10/my-topic-0/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/my-topic-0/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1742735936663 size: 78 magic: 2 compresscodec: none crc: 825983240 isvalid: true
| offset: 0 CreateTime: 1742735936663 keySize: 5 valueSize: 5 sequence: 0 headerKeys: [] key: 24910 payload: kafka
```

The consumer group should have committed its offsets to the `__consumer_offsets` internal topic.
Since this topic has 50 partitions by default, we need to determine which partition was used for your consumer group.
We can use the same hashing algorithm that Kafka employs to map a `group.id` to its coordinating partition.
The `kafka-cp` function, defined in the `init.sh` script, implements this algorithm.

```sh
$ get-cp my-group
12
```

Knowing that the consumer group commit was sent to `__consumer_offsets-12`, let's examine this partition.
The values are encoded for performance, so we must use the `--offsets-decoder` option to read them.

This partition contains various metadata, but we're particularly interested in records with the `offset_commit` key.
There's a batch from our consumer group containing 3 records, one for each input topic partition.
As expected, the consumer group committed offset 1 for partition 0, offset 2 for partition 2, and offset 0 for partition 1 (which didn't receive any messages).

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder \
  --files /var/lib/kafka/data/kafka-log10/__consumer_offsets-12/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/__consumer_offsets-12/00000000000000000000.log
Log starting offset: 0
...
baseOffset: 1 lastOffset: 3 count: 3 baseSequence: 0 lastSequence: 2 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 344 CreateTime: 1742735956644 size: 232 magic: 2 compresscodec: none crc: 4034662502 isvalid: true
| offset: 1 CreateTime: 1742735956644 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":0}} payload: {"version":"3","data":{"offset":1,"leaderEpoch":0,"metadata":"","commitTimestamp":1742735956641}}
| offset: 2 CreateTime: 1742735956644 keySize: 26 valueSize: 24 sequence: 1 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":1}} payload: {"version":"3","data":{"offset":0,"leaderEpoch":-1,"metadata":"","commitTimestamp":1742735956641}}
| offset: 3 CreateTime: 1742735956644 keySize: 26 valueSize: 24 sequence: 2 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"my-topic","partition":2}} payload: {"version":"3","data":{"offset":2,"leaderEpoch":0,"metadata":"","commitTimestamp":1742735956641}}
...
```
