## Transactions and how to rollback

Kafka provides **at-least-once semantics** by default and duplicates can arise due to either producer retries or consumer restarts after failure.
The **idempotent producer** configuration (now default) solves the duplicates problem by creating a producer session identified by a producer id (PID) and an epoch.
A sequence number is assigned when the record batch is first added to a produce request and it is never changed, even if the batch is resent.
That way, the broker hosting the partition leader can identify and filter out duplicates.

Unfortunately, the idempotent producer does not guarantee atomicity when you need to write to multiple partitions as a single unit of work.
Duplicates can also arise if you have two or more producer instances.
In all these cases, the **exactly-once semantics** (EOS) allows the desired all or nothing behavior when writing to distributed partitions.
The EOS in only supported inside a single Kafka cluster, excluding external systems (see the Outbox pattern and Spring TM).

![](images/trans.png)

Transactions are are typically used for **read-process-write** streaming applications where the EOS is required.
It is crucial that each application instance has its own static and unique `transactional.id` (TID), which is mapped to PID and epoch for zombie fencing.
A producer can have **only one ongoing transaction** (ordering guarantee).
Consumers with `isolation.level=read_committed` only receive committed messages, ignoring ongoing and discarding aborted transactions.
The EOS client overhead is minimal and you can tune tuning the `commit.interval.ms` to meet the required latency.
Enabling EOS with the Streams API is much easier than using the low level transaction API, as we just need to set `processing.guarantee=exactly_once_v2`.

The transaction state is stored in a specific `__transaction_state` partition, whose leader is a broker called the **transaction coordinator**. 
Each partition also contains `.snapshot` logs that helps in rebuilding the producers state in case of broker crash or restart.
The offset of the first still-open transaction is called the **last stable offset** (LSO <= HW).
The transaction coordinator automatically aborts any ongoing transaction that is not committed or aborted within `transaction.timeout.ms`.

Before Kafka 2.5.0 the TID had to be a static encoding of the input partition (i.e. `my-app.my-group.my-topic.0`), which also means one producer per partiton.
This was ugely inefficient but required to avoid the partition ownership transfer on CG rebalances, that would invalidate the fencing logic.
It was fixed by forcing the producer to send the consumer group metadata along with the offsets to commit (see `sendOffsetsToTransaction`).

### Example: transactional word counter

[Deploy a Kafka cluster on localhost](/sessions/001).
Run the demo application included in this session on a different terminal (there is a new poll/read every 60 seconds).
[Look at the code](/sessions/008/kafka-trans) to see how the low level transaction API is used.

```sh
$ mvn clean compile exec:java -f sessions/008/kafka-trans/pom.xml -q
Starting application instance with TID kafka-trans-0
Creating admin client
Topic wc-input created
Creating transactional producer
Creating transactional consumer
READ: Waiting for new user sentence
READ: Waiting for new user sentence
# ...
READ: Waiting for new user sentence
PROCESS: Computing word counts for wc-input-0
WRITE: Sending offsets and counts atomically
Topic wc-output created
```

Then, send one sentence to the input topic and check the result from the output topic.

```sh
$ kafka-console-producer.sh --bootstrap-server :9092 --topic wc-input
>a long time ago in a galaxy far far away
>^C

$ kafka-console-consumer.sh --bootstrap-server :9092 --topic wc-output \
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

Now we can stop the application (Ctrl+C) and take a look at partitions content.
Our output topic has one partition, but what are the `__consumer_offsets` and `__transaction_state`coordinating partitions?
We can use the same function that we saw in the first session passing the `group.id` and `transactional.id`.

```sh
$ find_cp my-group
12

$ find_cp kafka-trans-0
20
```

Let's now check what's happening inside all the partitions involved in this transaction.
In `wc-output-0` we see that the data batch is transactional (`isTransactional`) and contains the PID and epoch.
This batch is followed by a control batch (`isControl`), which contains a single end transaction marker record (`endTxnMarker`).
In `__consumer_offsets-12`, the CG offset commit batch (`key: offset_commit`) is followed by a similar control batch.

```sh
$ kafka-dump-log.sh --deep-iteration --print-data-log --files /tmp/kafka-logs/wc-output-0/00000000000000000000.log
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

$ kafka-dump-log.sh --deep-iteration --print-data-log --offsets-decoder --files /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Dumping /tmp/kafka-logs/__consumer_offsets-12/00000000000000000000.log
Starting offset: 0
# ...
baseOffset: 1 lastOffset: 1 count: 1 baseSequence: 0 lastSequence: 0 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: false deleteHorizonMs: OptionalLong.empty position: 339 CreateTime: 1665506597950 size: 118 magic: 2 compresscodec: none crc: 4199759988 isvalid: true
| offset: 1 CreateTime: 1665506597950 keySize: 26 valueSize: 24 sequence: 0 headerKeys: [] key: offset_commit::group=my-group,partition=wc-input-0 payload: offset=1
baseOffset: 2 lastOffset: 2 count: 1 baseSequence: -1 lastSequence: -1 producerId: 0 producerEpoch: 0 partitionLeaderEpoch: 0 isTransactional: true isControl: true deleteHorizonMs: OptionalLong.empty position: 457 CreateTime: 1665506597998 size: 78 magic: 2 compresscodec: none crc: 3355926470 isvalid: true
| offset: 2 CreateTime: 1665506597998 keySize: 4 valueSize: 6 sequence: -1 headerKeys: [] endTxnMarker: COMMIT coordinatorEpoch: 0
# ...
```

That was straightforward, but how the transaction state is managed by the coordinator? 
In `__transaction_state-20` record payloads we can see all transaction state changes keyed by TID `kafka-trans-0` (we also have PID+epoch).
The transaction starts in the `Empty` state, then we have two `Ongoing` state changes (one for each partition registration).
Then, when the commit is called, we have `PrepareCommit` state change, which means the broker is now doomed to commit.
This happens in the last batch, where the state is changed to `CompleteCommit`, terminating  the transaction.

```sh
$ kafka-dump-log.sh --deep-iteration --print-data-log --transaction-log-decoder --files /tmp/kafka-logs/__transaction_state-20/00000000000000000000.log
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

### Example: hanging transaction rollback

A hanging transaction is one which has a missing or out of order control record, due to a bug in the transaction handling.
If a transaction is being left in an open state (no end TX marker), the LSO is stuck, which also means that any `read_committed` consumer is blocked.
This is the typical error you would see in older Kafka releases.

```sh
[Consumer clientId=my-client, groupId=my-group] The following partitions still have unstable offsets which are not cleared on the broker side: [my-topic-9], 
this could be either transactional offsets waiting for completion, or normal offsets waiting for replication after appending to local log
```

If producers continue to send messages to that partition, you should be able to see a growing CG lag.
If the stuck partition belongs to a compacted topic, you should also have an unbounded partition growth, which in turn canlead to disk exhaustion and broker crash.
Log cleaner threads never clean beyond the LSO and they select the partition with the highest dirty ratio (dirtyEntries/totalEntries).
In this case the LSO is stuck, so that ratio remains constant and the partition is never cleaned.

```sh
$ kafka-consumer-groups.sh --bootstrap-server :9092 --describe --group my-group
GROUP     TOPIC                  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG   CONSUMER-ID  HOST           CLIENT-ID
my-group  __consumer_offsets-27  9          913095344       913097449       2115  my-client-0  /10.60.172.97  my-client

# last cleaned offset never changes
$ grep "my-topic $(find_cp my-group)" /opt/kafka/data/kafka-0/cleaner-offset-checkpoint
my-topic 9 913090100
```

To unblock these stuck consumers, we need to identify and rollback the hanging transaction.
This is not an easy task without some tools and knowledge about how EOS works (see previous example).

First, dump the partition segment that includes the blocked offset and all snapshot files of that partition.
You can easily determine which segment you need to dump, because every segment name is named after the first offset it contains.
Note that it is required to run the following commands inside the partition directory containing the row segments.

```sh
$ tar xzf sessions/008/raw/__consumer_offsets-27.tgz -C ~/Downloads
$ cd ~/Downloads/__consumer_offsets-27
$ kafka-dump-log.sh --deep-iteration --files 00000000000912375285.log > 00000000000912375285.log.dump
$ kafka-dump-log.sh --deep-iteration --files 00000000000933607637.snapshot > 00000000000933607637.snapshot.dump
```

Now, you need to install and use a tool called `klog`, which is able to parse segment dumps and identify any open transaction (`open_txn`).
Note that from `klog segment` output we can get the transaction PID and epoch.

```sh
$ git clone https://github.com/tombentley/klog
$ cd klog && mvn clean package -DskipTests -Pnative -Dquarkus.native.container-build=true -q
$ cp target/*-runner ~/.local/bin/klog

$ klog segment txn-stat 00000000000912375285.log.dump | grep "open_txn" | head -n1
open_txn: ProducerSession[producerId=171100, producerEpoch=1]->FirstBatchInTxn[firstBatchInTxn=Batch(baseOffset=913095344, lastOffset=913095344, count=1, baseSequence=0, lastSequence=0, producerId=171100, producerEpoch=1, partitionLeaderEpoch=38, isTransactional=true, isControl=false, position=76752106, createTime=2022-06-06T03:16:47.124Z, size=128, magic=2, compressCodec='none', crc=-2141709867, isValid=true), numDataBatches=1]
```

If there is no open transaction, then it means that the topic retention kicked in and the records were deleted.
In this case you can simply delete all `.snapshot` files in the stuck partition's folder and do a cluster rolling restart.

Instead, if there are open transactions, you need to rollback them by using the Kafka command printed by `klog snapshot`.
Note that the `CLUSTER_ACTION` operation is required if authorization is enabled.

```sh
$ klog snapshot abort-cmd 00000000000933607637.snapshot.dump --pid 171100 --producer-epoch 1
$KAFKA_HOME/bin/kafka-transactions.sh --bootstrap-server $BOOTSTRAP_URL abort --topic $TOPIC_NAME --partition $PART_NUM --producer-id 171100 --producer-epoch 1 --coordinator-epoch 34
```
