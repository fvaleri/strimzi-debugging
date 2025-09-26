## Running transactional applications

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Then, run a transactional application example (read-process-write).

```sh
$ kubectl create -f sessions/010/install.yaml
kafkatopic.kafka.strimzi.io/input-topic created
kafkatopic.kafka.strimzi.io/output-topic created
statefulset.apps/kafka-txn created
```

When the application is running, we send one sentence to the input topic and check the result from the output topic.

```sh
$ kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic input-topic
>this is a test
>^C

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic output-topic --from-beginning
tset a si siht
^CProcessed a total of 1 messages
```

After that, we can take a look at partition content.
Our output topic has one partition, but what are the `__consumer_offsets` and `__transaction_state` coordinating partitions?
We can pass the `group.id` and `transactional.id` to the following function define in `init.sh` to find out.

```sh
$ kafka-cp my-group
12

$ kafka-cp kafka-txn-0
30
```

We now check what's happening inside all the partitions involved in this transaction.
In `output-topic-0`, we see that the data batch is transactional (`isTransactional`) and contains the PID and epoch.
This batch is followed by a control batch (`isControl`), which contains a single end transaction marker record (`endTxnMarker`).
In `__consumer_offsets-12`, the consumer group's offset commit batch is followed by a similar control batch.

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

That was straightforward, but how is the transaction state managed by the coordinator? 
In `__transaction_state-20` record payloads, we can see all transaction state changes keyed by TID `kafka-txn-0` (we also have PID+epoch).
The transaction starts in the `Empty` state, then we have two `Ongoing` state changes (one for each partition registration).
Then, when the commit is called, we have `PrepareCommit` state change, which means the broker is now committed to the transaction.
This happens in the last batch, where the state is changed to `CompleteCommit`, terminating the transaction.

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

## Transaction rollback

When there is a hanging transaction the LSO is stuck, which means that transactional consumers of this partition can't make any progress (CURRENT-OFFSET==LSO).

```sh
# application log
[Consumer clientId=my-client, groupId=my-group] The following partitions still have unstable offsets which are not cleared on the broker side: [__consumer_offsets-27], 
this could be either transactional offsets waiting for completion, or normal offsets waiting for replication after appending to local log

# consumer lag grows
$ kubectl-kafka bin/kafka-consumer-groups.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --group my-group
GROUP     TOPIC                  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG   CONSUMER-ID  HOST           CLIENT-ID
my-group  __consumer_offsets-27  9          913095344       913097449       2105  my-client-0  /10.60.172.97  my-client
```

If the partition is part of a compacted topic like `__consumer_offsets`, compaction is also blocked, causing unbounded partition growth.
The last cleaned offset never changes.

```sh
$ kubectl exec -it my-cluster-broker-10 -- bash

[kafka@my-cluster-broker-10 kafka]$ grep "__consumer_offsets 27" /var/lib/kafka/data/kafka-log10/cleaner-offset-checkpoint
__consumer_offsets 27 913095344

[kafka@my-cluster-broker-10 kafka]$ exit
exit
```

In Kafka 3+ there is an official command line tool that you can use to identify and rollback hanging transactions.

> [!IMPORTANT]  
> The `CLUSTER_ACTION` operation type is required when authorization is enabled.

```sh
$ kubectl-kafka bin/kafka-transactions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 find-hanging --broker 10
Topic                  Partition   ProducerId  ProducerEpoch   StartOffset LastTimestamp               Duration(s)
__consumer_offsets     27          171100      1               913095344   2022-06-06T03:16:47Z        209793

$ kubectl-kafka bin/kafka-transactions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 abort \
  --topic __consumer_offsets --partition 27 --start-offset 913095344
```
