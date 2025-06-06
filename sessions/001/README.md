## Deploy a Kafka cluster

In this example, we deploy a Kafka cluster to a Kubernetes cluster using the operator.
Use the `init.sh` script to easily initialize or reset the test environment.

> [!IMPORTANT]  
> Login first if your Kubernetes cluster requires authentication.

```sh
$ source init.sh
Deploying Strimzi
namespace/test created
Done
```

Then, we create a new Kafka cluster and test topic.
In the YAML files, we can see how the desired cluster state is declared.

In addition to Kafka pods, the Entity Operator (EO) pod is also deployed, which includes two namespaced operators: the Topic Operator (TO), and the User Operator (UO).
These operators only support a single namespace and a single Kafka cluster.

```sh
$ kubectl create -f sessions/001/install.yaml
kafkanodepool.kafka.strimzi.io/controller created
kafkanodepool.kafka.strimzi.io/broker created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get sps,knp,k,kt,po
NAME                                                  PODS   READY PODS   CURRENT PODS   AGE
strimzipodset.core.strimzi.io/my-cluster-broker       3      3            3              65s
strimzipodset.core.strimzi.io/my-cluster-controller   3      3            3              65s

NAME                                        DESIRED REPLICAS   ROLES            NODEIDS
kafkanodepool.kafka.strimzi.io/broker       3                  ["broker"]       [5,6,7]
kafkanodepool.kafka.strimzi.io/controller   3                  ["controller"]   [0,1,2]

NAME                                DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   METADATA STATE   WARNINGS
kafka.kafka.strimzi.io/my-cluster                                                                           

NAME                                   CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/my-topic   my-cluster   3            3                    True

NAME                                             READY   STATUS    RESTARTS   AGE
pod/my-cluster-broker-10                         1/1     Running   0          64s
pod/my-cluster-broker-11                         1/1     Running   0          64s
pod/my-cluster-broker-12                         1/1     Running   0          64s
pod/my-cluster-controller-0                      1/1     Running   0          63s
pod/my-cluster-controller-1                      1/1     Running   0          63s
pod/my-cluster-controller-2                      1/1     Running   0          63s
pod/my-cluster-entity-operator-bb7c65dd4-9zdmk   2/2     Running   0          31s
pod/strimzi-cluster-operator-6596f469c9-smsw2    1/1     Running   0          2m5s
```

When the Kafka cluster is ready, we send and receive some messages.
When consuming messages, you can print additional data such as the partition number.
Every consumer with the same `group.id` is part of the same consumer group.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic \
  --property parse.key=true --property key.separator="#"
>32947#hello
>24910#kafka
>45237#world
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic \
  --group my-group --from-beginning --max-messages 3 --property print.partition=true --property print.key=true
Partition:0	24910	kafka
Partition:2	32947	hello
Partition:2	45237	world
Processed a total of 3 messages
```

It works, but where our messages are being stored?
The broker property `log.dirs` configures where our topic partitions are stored.
We have 3 partitions, which corresponds to exactly 3 folders on disk.

```sh
$ kubectl exec my-cluster-broker-10 -- cat /tmp/strimzi.properties | grep log.dirs
log.dirs=/var/lib/kafka/data/kafka-log10

$ kubectl exec my-cluster-broker-10 -- ls -lh /var/lib/kafka/data/kafka-log10 | grep my-topic
drwxr-xr-x. 2 kafka root  167 Mar 23 13:18 my-topic-0
drwxr-xr-x. 2 kafka root  167 Mar 23 13:15 my-topic-1
drwxr-xr-x. 2 kafka root  167 Mar 23 13:18 my-topic-2
```

The consumer output shows that messages were sent to partition 0 and 2.
Looking inside partition 0, we have a `.log` file containing our records (each segment is named after the initial offset), an `.index` file mapping the record offset to its position in the log and a `.timeindex` file mapping the record timestamp to its position in the log.
The other two files contain additional metadata.

```sh
$ kubectl exec my-cluster-broker-10 -- ls -lh /var/lib/kafka/data/kafka-log10/my-topic-0
total 12K
-rw-r--r--. 1 kafka root 10M Mar 23 13:15 00000000000000000000.index
-rw-r--r--. 1 kafka root  78 Mar 23 13:18 00000000000000000000.log
-rw-r--r--. 1 kafka root 10M Mar 23 13:15 00000000000000000000.timeindex
-rw-r--r--. 1 kafka root   8 Mar 23 13:18 leader-epoch-checkpoint
-rw-r--r--. 1 kafka root  43 Mar 23 13:15 partition.metadata
```

Partition log files are in binary format, but Kafka includes a dump tool for decoding them.
On this partition, we have one batch (`baseOffset`), containing only one record (`| offset`) with key "24910" and payload "kafka".

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log \
  --files /var/lib/kafka/data/kafka-log10/my-topic-0/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/my-topic-0/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1742735936663 size: 78 magic: 2 compresscodec: none crc: 825983240 isvalid: true
| offset: 0 CreateTime: 1742735936663 keySize: 5 valueSize: 5 sequence: 0 headerKeys: [] key: 24910 payload: kafka
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
As expected, the consumer group committed offset1@partition0, offset2@partition2, and offset0@partition1 (this partition didn't received any message).

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
