# Transactions and how to rollback

Kafka provides at-least-once semantics by default, so duplicates can arise because of producer retries or consumer restarts after failure.
The idempotent producer configuration (now default) solves the duplicates problem by creating a producer session identified by a producer id (PID) and an epoch.
A sequence number is assigned when the record batch is first added to a produce request and it is never changed, even if the batch is resent.
That way, the broker hosting the partition leader can identify and filter out duplicates.

Unfortunately, the idempotent producer does not guarantee atomicity when you need to write to multiple partitions as a single unit of work.
This is usually the case for read-process-write applications, where the exactly-once semantics (EOS) allow atomic writes to multiple partitions.
The EOS is only supported inside a single Kafka cluster, excluding any external system.

> Where EOS is required for atomic writes to multiple partitions, the Outbox pattern and Spring Transaction Manager (TM) can be used.

![](images/trans.png)

Each producer instance must have its own static and unique `transactional.id` (TID), which is mapped to a producer id (PID) and epoch (to implement zombie fencing).
Consumers with `isolation.level=read_committed` only get committed messages, ignoring ongoing and aborted transactions.

A given producer can have at most one ongoing transaction (ordering guarantee).
The transaction state is stored in an internal topic called `__transaction_state`.
The transaction coordinator automatically aborts any ongoing transaction that is not completed within `transaction.timeout.ms`.

A transaction goes through the following states:

1. Ongoing (undecided)
2. Completed and unreplicated (decided)
3. Completed and replicated (decided and committed)

The first unstable offset (FUO) is the earliest offset that is part of an ongoing transaction, if any.
The last stable offset (LSO) is the offset such that all lower offsets have been decided and it is always present.
Non-transactional batches are considered decided immediately, but transactional batches are only decided when the corresponding commit or abort marker is written.
This means that the LSO is equal to the FUO if it's lower than the high watermark (HW), otherwise it's the HW.

The `LogCleaner` does not clean beyond the LSO.
If there is a hanging transaction on a partition (missing or out of order control record), the FUO can't be updated, which means the LSO is stuck.
At this point, transactional consumers can't make progress and compaction is blocked if enabled.
After transaction rollback, the LSO starts to increment again on every completed transaction.

# Example: transactional application

First, we [deploy the AMQ Streams operator and Kafka cluster](/sessions/001).
We run the word count application included in this session on a different terminal (there is a new poll/read every 60 seconds).
[Look at the code](/sessions/008/kafka-trans) to see how the low-level transaction API is used.

```sh
export BOOTSTRAP_SERVERS="localhost:9092" \
       GROUP_ID="my-group" \
       INSTANCE_ID="kafka-trans-0" \
       INPUT_TOPIC="wc-input" \
       OUTPUT_TOPIC="wc-output"

mvn clean compile exec:java -f sessions/008/kafka-trans/pom.xml -q
Starting application instance with TID kafka-trans-0
Topic wc-input created
READ: Waiting for new user sentence
READ: Waiting for new user sentence
# ...
READ: Waiting for new user sentence
PROCESS: Computing word counts for wc-input-0
WRITE: Sending offsets and counts atomically
Topic wc-output created
```

Then, we send one sentence to the input topic and check the result from the output topic.

```sh
kafka-console-producer.sh --bootstrap-server :9092 --topic wc-input
>a long time ago in a galaxy far far away
>^C

kafka-console-consumer.sh --bootstrap-server :9092 --topic wc-output \
  --from-beginning --property print.key=true --property print.value=true
a	2
away	1
in	1
far	2
ago	1
time	1
galaxy	1
long	1
^CProcessed a total of 8 messages
```

Now we can stop the application (Ctrl+C) and take a look at partition content.
Our output topic has one partition, but what are the `__consumer_offsets` and `__transaction_state` coordinating partitions?
We can pass the `group.id` and `transactional.id` to find out.

```sh
kafka-cp my-group
12

kafka-cp kafka-trans-0
20
```

We now check what's happening inside all the partitions involved in this transaction.
In `wc-output-0`, we see that the data batch is transactional (`isTransactional`) and contains the PID and epoch.
This batch is followed by a control batch (`isControl`), which contains a single end transaction marker record (`endTxnMarker`).
In `__consumer_offsets-12`, the CG offset commit batch (`key: offset_commit`) is followed by a similar control batch.

```sh
kafka-dump-log.sh --deep-iteration --print-data-log --files /tmp/kafka-logs/wc-output-0/00000000000000000000.log
Dumping /tmp/kafka-logs/wc-output-0/00000000000000000000.log
Starting offset: 0
baseOffset: 0 lastOffset: 7 count: 8 baseSequence: 0 lastSequence: 7 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1665506597828 size: 152 magic: 2 compresscodec: none crc: 3801140420 isvalid: true
| offset: 0 CreateTime: 1665506597822 keySize: 1 valueSize: 1 sequence: 0 headerKeys: [] key: a payload: 2
| offset: 1 CreateTime: 1665506597827 keySize: 4 valueSize: 1 sequence: 1 headerKeys: [] key: away payload: 1
| offset: 2 CreateTime: 1665506597828 keySize: 2 valueSize: 1 sequence: 2 headerKeys: [] key: in payload: 1
| offset: 3 CreateTime: 1665506597828 keySize: 3 valueSize: 1 sequence: 3 headerKeys: [] key: far payload: 2
| offset: 4 CreateTime: 1665506597828 keySize: 3 valueSize: 1 sequence: 4 headerKeys: [] key: ago payload: 1
| offset: 5 CreateTime: 1665506597828 keySize: 4 valueSize: 1 sequence: 5 headerKeys: [] key: time payload: 1
| offset: 6 CreateTime: 1665506597828 keySize: 6 valueSize: 1 sequence: 6 headerKeys: [] key: galaxy payload: 1
| offset: 7 CreateTime: 1665506597828 keySize: 4 valueSize: 1 sequence: 7 headerKeys: [] key: long payload: 1
baseOffset: 8 lastOffset: 8 count: 1 baseSequence: -1 lastSequence: -1 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: true deleteHorizonMs: OptionalLong.empty position: 152 CreateTime: 1665506597998 size: 78 magic: 2 compresscodec: none crc: 3355926470 isvalid: true
| offset: 8 CreateTime: 1665506597998 keySize: 4 valueSize: 6 sequence: -1 headerKeys: [] endTxnMarker: COMMIT coordinatorEpoch: 0

kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder --files /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Dumping /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Starting offset: 0
# ...
baseOffset: 1 lastOffset: 1 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: false deleteHorizonMs: OptionalLong.empty position: 339 CreateTime: 1665506597950 size: 118 magic: 2 compresscodec: none crc: 4199759988 isvalid: true
| offset: 1 CreateTime: 1665506597950 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: offset_commit::group=my-group,partition=wc-input-0 payload: offset=1
baseOffset: 2 lastOffset: 2 count: 1 baseSequence: -1 lastSequence: -1 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: true deleteHorizonMs: OptionalLong.empty position: 457 CreateTime: 1665506597998 size: 78 magic: 2 compresscodec: none crc: 3355926470 isvalid: true
| offset: 2 CreateTime: 1665506597998 keySize: 4 valueSize: 6 sequence: -1 headerKeys: [] endTxnMarker: COMMIT coordinatorEpoch: 0
# ...
```

That was straightforward, but how is the transaction state managed by the coordinator? 
In `__transaction_state-20` record payloads, we can see all transaction state changes keyed by TID `kafka-trans-0` (we also have PID+epoch).
The transaction starts in the `Empty` state, then we have two `Ongoing` state changes (one for each partition registration).
Then, when the commit is called, we have `PrepareCommit` state change, which means the broker is now committed to the transaction.
This happens in the last batch, where the state is changed to `CompleteCommit`, terminating  the transaction.

```sh
kafka-dump-log.sh --deep-iteration --print-data-log --transaction-log-decoder --files /tmp/kafka-logs/__transaction_state-20/00000000000000000000.log
Dumping /tmp/kafka-logs/__transaction_state-20/00000000000000000000.log
Starting offset: 0
baseOffset: 0 lastOffset: 0 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 0 CreateTime: 1665506545539 size: 130 magic: 2 compresscodec: none crc: 682337358 isvalid: true
| offset: 0 CreateTime: 1665506545539 keySize: 24 valueSize: 37 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-trans-0 payload: producerId:0,producerEpoch:0,state=Empty,partitions=[],txnLastUpdateTimestamp=1665506545533,txnTimeoutMs=60000
baseOffset: 1 lastOffset: 1 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 130 CreateTime: 1665506597832 size: 149 magic: 2 compresscodec: none crc: 3989189852 isvalid: true
| offset: 1 CreateTime: 1665506597832 keySize: 24 valueSize: 56 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-trans-0 payload: producerId:0,producerEpoch:0,state=Ongoing,partitions=[wc-output-0],txnLastUpdateTimestamp=1665506597831,txnTimeoutMs=60000
baseOffset: 2 lastOffset: 2 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 279 CreateTime: 1665506597836 size: 178 magic: 2 compresscodec: none crc: 4121781109 isvalid: true
| offset: 2 CreateTime: 1665506597836 keySize: 24 valueSize: 84 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-trans-0 payload: producerId:0,producerEpoch:0,state=Ongoing,partitions=[__consumer_offsets-12,wc-output-0],txnLastUpdateTimestamp=1665506597836,txnTimeoutMs=60000
baseOffset: 3 lastOffset: 3 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 457 CreateTime: 1665506597988 size: 178 magic: 2 compresscodec: none crc: 1820961623 isvalid: true
| offset: 3 CreateTime: 1665506597988 keySize: 24 valueSize: 84 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-trans-0 payload: producerId:0,producerEpoch:0,state=PrepareCommit,partitions=[__consumer_offsets-12,wc-output-0],txnLastUpdateTimestamp=1665506597987,txnTimeoutMs=60000
baseOffset: 4 lastOffset: 4 count: 1 baseSequence: -1 lastSequence: -1 producerId: -1 producerEpoch: -1 partitionLeaderEpoch: 0 isTransactional: false isControl: false deleteHorizonMs: OptionalLong.empty position: 635 CreateTime: 1665506598005 size: 130 magic: 2 compresscodec: none crc: 4065405397 isvalid: true
| offset: 4 CreateTime: 1665506598005 keySize: 24 valueSize: 37 sequence: -1 headerKeys: [] key: transaction_metadata::transactionalId=kafka-trans-0 payload: producerId:0,producerEpoch:0,state=CompleteCommit,partitions=[],txnLastUpdateTimestamp=1665506597989,txnTimeoutMs=60000
```

# Example: transaction rollback

When there is a hanging transaction the LSO is stuck, which means that transactional consumers of this partition can't make any progress (CURRENT-OFFSET==LSO).

```sh
# application log
[Consumer clientId=my-client, groupId=my-group] The following partitions still have unstable offsets which are not cleared on the broker side: [__consumer_offsets-27], 
this could be either transactional offsets waiting for completion, or normal offsets waiting for replication after appending to local log

# consumer lag grows
kafka-consumer-groups.sh --bootstrap-server :9092 --describe --group my-group
GROUP     TOPIC                  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG   CONSUMER-ID  HOST           CLIENT-ID
my-group  __consumer_offsets-27  9          913095344       913097449       2105  my-client-0  /10.60.172.97  my-client
```

If the partition is part of a compacted topic like `__consumer_offsets`, compaction is also blocked, causing unbounded partition growth.

```sh
# last cleaned offset never changes
grep "__consumer_offsets 27" /opt/kafka/data/kafka-0/cleaner-offset-checkpoint
__consumer_offsets 27 913095344
```

In Kafka 3+ there is an official command line tool that you can use to identify and rollback hanging transactions.
Note that the `CLUSTER_ACTION` operation is required if authorization is enabled.

```sh
kafka-transactions.sh --bootstrap-server :9092 find-hanging --broker 0
Topic                  Partition   ProducerId  ProducerEpoch   StartOffset LastTimestamp               Duration(s)
__consumer_offsets     27          171100      1               913095344   2022-06-06T03:16:47Z        209793

kafka-transactions.sh --bootstrap-server :9092 abort --topic __consumer_offsets --partition 27 --start-offset 913095344
```

If you are using an older version and hanging transactions are still in the logs, then the procedure is more complicated.
First, dump the partition segment that includes the LSO and all snapshot files of that partition.

```sh
kafka-dump-log.sh --deep-iteration --files 00000000000912375285.log > 00000000000912375285.log.dump
kafka-dump-log.sh --deep-iteration --files 00000000000933607637.snapshot > 00000000000933607637.snapshot.dump
```

Then, use `klog segment` to parse the segment dumps and identify the hanging transactions.

```sh
git clone https://github.com/tombentley/klog
cd klog && mvn clean package -DskipTests -Pnative -Dquarkus.native.container-build=true
cp target/*-runner ~/.local/bin/klog

klog segment txn-stat 00000000000912375285.log.dump | grep "open_txn" | head -n1
open_txn: ProducerSession[producerId=171100, producerEpoch=1]->FirstBatchInTxn[firstBatchInTxn=Batch(baseOffset=913095344, lastOffset=913095344, count=1, baseSequence=0, lastSequence=0, producerId=171100, producerEpoch=1, partitionLeaderEpoch=38, isTransactional=true, isControl=false, position=76752106, createTime=2022-06-06T03:16:47.124Z, size=128, magic=2, compressCodec='none', crc=-2141709867, isValid=true), numDataBatches=1]
```

If the `open_txn` is the last segment batch, then it may be closed in the next segment (false positive).
Otherwise, we can rollback the hanging transaction by running the command printed out by `klog snapshot`.

```sh
klog snapshot abort-cmd 00000000000933607637.snapshot.dump --pid 171100 --producer-epoch 1
$KAFKA_HOME/bin/kafka-transactions.sh --bootstrap-server $BOOTSTRAP_URL abort --topic $TOPIC_NAME --partition $PART_NUM --producer-id 171100 --producer-epoch 1 --coordinator-epoch 34
```
