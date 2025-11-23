## Running Transactional Applications

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Next, run a transactional application example implementing a read-process-write pattern.

```sh
$ kubectl create -f sessions/010/install.yaml
kafkatopic.kafka.strimzi.io/input-topic created
kafkatopic.kafka.strimzi.io/output-topic created
statefulset.apps/kafka-txn created
```

Once the application is running, send a sentence to the input topic and verify the result from the output topic.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic input-topic
>this is a test
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic output-topic --from-beginning
tset a si siht
^CProcessed a total of 1 messages
```

Next, examine the partition content.
The output topic has one partition, but which `__consumer_offsets` and `__transaction_state` partitions coordinate this transaction?
Pass the `group.id` and `transactional.id` to the function defined in `init.sh` to determine the coordinating partitions.

```sh
$ kafka-cp my-group
12

$ kafka-cp kafka-txn-0
30
```

Examine what's happening inside all partitions involved in this transaction.
In `output-topic-0`, the data batch has `isTransactional` set to true and includes the Producer ID (PID) and epoch.
A control batch (`isControl`) follows, containing a single transaction end marker record (`endTxnMarker`).
Similarly, in `__consumer_offsets-12`, the consumer group's offset commit batch is followed by a control batch.

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log \
  --files /var/lib/kafka/data/kafka-log10/output-topic-0/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/output-topic-0/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: 0 lastSequence: 0 producerId: 1 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1742739702864 size: 82 magic: 2 compresscodec: none crc: 758896000 isvalid: true
| offset: 0 CreateTime: 1742739702864 keySize: -1 valueSize: 14 sequence: 0 headerKeys: [] payload: tset a si siht
baseOffset: 1 lastOffset: 1 count: 1 baseSequence: -1 lastSequence: -1 producerId: 1 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: true deleteHorizonMs: OptionalLong.empty position: 82 CreateTime: 1742739703234 size: 78 magic: 2 compresscodec: none crc: 2557578104 isvalid: true
| offset: 1 CreateTime: 1742739703234 keySize: 4 valueSize: 6 sequence: -1 headerKeys: [] endTxnMarker: COMMIT coordinatorEpoch: 0

$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder \
  --files /var/lib/kafka/data/kafka-log10/__consumer_offsets-12/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/__consumer_offsets-12/00000000000000000000.log
Log starting offset: 0
...
baseOffset: 7 lastOffset: 7 count: 1 baseSequence: 0 lastSequence: 0 producerId: 1 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: false deleteHorizonMs: OptionalLong.empty position: 1974 CreateTime: 1742739703027 size: 121 magic: 2 compresscodec: none crc: 4292816145 isvalid: true
| offset: 7 CreateTime: 1742739703027 keySize: 29 valueSize: 24 sequence: 0 headerKeys: [] key: {"type":"1","data":{"group":"my-group","topic":"input-topic","partition":0}} payload: {"version":"3","data":{"offset":1,"leaderEpoch":-1,"metadata":"","commitTimestamp":1742739702993}}
baseOffset: 8 lastOffset: 8 count: 1 baseSequence: -1 lastSequence: -1 producerId: 1 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: true deleteHorizonMs: OptionalLong.empty position: 2095 CreateTime: 1742739703213 size: 78 magic: 2 compresscodec: none crc: 1231080676 isvalid: true
| offset: 8 CreateTime: 1742739703213 keySize: 4 valueSize: 6 sequence: -1 headerKeys: [] endTxnMarker: COMMIT coordinatorEpoch: 0
...
```

That's the data flow, but how does the coordinator manage transaction state?
In `__transaction_state-30` record payloads, observe all state changes keyed by transaction ID (TID) `kafka-txn-0`, along with PID and epoch.
The transaction begins in the `Empty` state, followed by two `Ongoing` state changes as each partition registers.
When commit is called, the state changes to `PrepareCommit`, indicating the broker's commitment to the transaction.
Finally, the state changes to `CompleteCommit` in the last batch, terminating the transaction.

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log --transaction-log-decoder \
  --files /var/lib/kafka/data/kafka-log10/__transaction_state-30/00000000000000000000.log
Dumping /var/lib/kafka/data/kafka-log10/__transaction_state-30/00000000000000000000.log
Log starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1742739549438 size: 120 magic: 2 compresscodec: none crc: 3663501755 isvalid: true
| offset: 0 CreateTime: 1742739549438 keySize: 15 valueSize: 37 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-txn-0 payload: producerId:1,producerEpoch:0,state=Empty,partitions=[],txnLastUpdateTimestamp=1742739549435,txnTimeoutMs=60000
baseOffset: 1 lastOffset: 1 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 120 CreateTime: 1742739702876 size: 143 magic: 2 compresscodec: none crc: 563111626 isvalid: true
| offset: 1 CreateTime: 1742739702876 keySize: 15 valueSize: 59 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-txn-0 payload: producerId:1,producerEpoch:0,state=Ongoing,partitions=[output-topic-0],txnLastUpdateTimestamp=1742739702876,txnTimeoutMs=60000
baseOffset: 2 lastOffset: 2 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 263 CreateTime: 1742739702882 size: 172 magic: 2 compresscodec: none crc: 1296972565 isvalid: true
| offset: 2 CreateTime: 1742739702882 keySize: 15 valueSize: 87 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-txn-0 payload: producerId:1,producerEpoch:0,state=Ongoing,partitions=[output-topic-0,__consumer_offsets-12],txnLastUpdateTimestamp=1742739702882,txnTimeoutMs=60000
baseOffset: 3 lastOffset: 3 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 435 CreateTime: 1742739703134 size: 172 magic: 2 compresscodec: none crc: 598474139 isvalid: true
| offset: 3 CreateTime: 1742739703134 keySize: 15 valueSize: 87 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-txn-0 payload: producerId:1,producerEpoch:0,state=PrepareCommit,partitions=[output-topic-0,__consumer_offsets-12],txnLastUpdateTimestamp=1742739703132,txnTimeoutMs=60000
baseOffset: 4 lastOffset: 4 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 607 CreateTime: 1742739703240 size: 120 magic: 2 compresscodec: none crc: 4205821491 isvalid: true
| offset: 4 CreateTime: 1742739703240 keySize: 15 valueSize: 37 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-txn-0 payload: producerId:1,producerEpoch:0,state=CompleteCommit,partitions=[],txnLastUpdateTimestamp=1742739703142,txnTimeoutMs=60000
```

## Transaction Rollback

When a transaction hangs, the Log Stable Offset (LSO) becomes stuck, preventing transactional consumers from making progress on this partition (CURRENT-OFFSET==LSO).

```sh
# application log
[Consumer clientId=my-client, groupId=my-group] The following partitions still have unstable offsets which are not cleared on the broker side: [__consumer_offsets-27], 
this could be either transactional offsets waiting for completion, or normal offsets waiting for replication after appending to local log

# consumer lag grows
$ kubectl-kafka bin/kafka-consumer-groups.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --group my-group
GROUP     TOPIC                  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG   CONSUMER-ID  HOST           CLIENT-ID
my-group  __consumer_offsets-27  9          913095344       913097449       2105  my-client-0  /10.60.172.97  my-client
```

If the partition belongs to a compacted topic like `__consumer_offsets`, compaction is also blocked, leading to unbounded partition growth.
The last cleaned offset remains frozen.

```sh
$ kubectl exec -it my-cluster-broker-10 -- bash

[kafka@my-cluster-broker-10 kafka]$ grep "__consumer_offsets 27" /var/lib/kafka/data/kafka-log10/cleaner-offset-checkpoint
__consumer_offsets 27 913095344

[kafka@my-cluster-broker-10 kafka]$ exit
exit
```

Kafka 3.0+ includes an official command-line tool for identifying and rolling back hanging transactions.

> [!IMPORTANT]
> When authorization is enabled, the `CLUSTER_ACTION` operation type is required to use this tool.

```sh
$ kubectl-kafka bin/kafka-transactions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 find-hanging --broker 10
Topic                  Partition   ProducerId  ProducerEpoch   StartOffset LastTimestamp               Duration(s)
__consumer_offsets     27          171100      1               913095344   2022-06-06T03:16:47Z        209793

$ kubectl-kafka bin/kafka-transactions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 abort \
  --topic __consumer_offsets --partition 27 --start-offset 913095344
```
