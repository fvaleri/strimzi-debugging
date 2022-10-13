## Cruise Control and unbalanced clusters

By default, Kafka try to distribute the load evenly across brokers. This is achieved through the concept of **preferred
replica**, which is the first replica created for a new topic. This is designated as the leader and assigned to a broker
in order to balance leader distribution. A background thread moves leader to preferred replica when it is in sync.

Sometimes, this may not be enough and we may end up with **uneven distribution of load across brokers** as a consequence
of some broker failures, the addition of new brokers or simply because some partitions are used more than others.
The `kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent` broker metric is a good overall load
metric for Kafka scaling and rebalance decisions. Good rule of thumb is when it hits 20% (i.e. the request handler
threads are busy 80% of the time), then it's time to plan your cluster expansion, at 10% you need to scale it now.

**Rebalancing** means moving partitions between brokers (inter brokers), between disks on the same broker
(intra broker), or simply change leaders in order to restore the balance. Usually we need some combination of partition
movements and leadership changes. When using `kafka-reassign-partitions.sh` for rebalancing, the task of figuring out
which replica changes are needed and possible is left to the user. This requires some calculations that may be hard and
time consuming, especially on big clusters with lots of partitions. Automating this complex task is the reason
why [Cruise Control](https://github.com/linkedin/cruise-control) (CC) was created.

![](images/cc.png)

A replica level **workload model** is periodically updated from the resource utilization metrics (CPU, disk, bytes-in,
bytes-out). The analyzer component uses this model to create a valid **rebalance proposal** when possible (one that must
satisfy all configured hard goals, and possibly soft goals too). The executor ensures that there is only one active
execution at a time and enables graceful cancellation applying changes in batches. If two equivalent changes are
possible, the one with the lower cost is selected (leadership change > replica move > replica swap).

As of today, Streams still requires the manual approval of the auto-generated rebalance proposal, but we are working to
enable full automation. In order to have accurate rebalance proposals when using CPU goals, we can set CPU requests
equal to CPU limits in `spec.kafka.resources`. That way, all CPU resources are reserved upfront and are always
available. This allows CC to properly evaluate the CPU utilization when preparing the rebalance proposals.

### Example: scaling up the cluster

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, we want to scale it up and move
some replicas to the new broker in order to reduce the load on the other brokers. Thanks to the CO, we can scale the
cluster up by simply raising the number of broker replicas in the Kafka CR.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        replicas: 4'
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl get po -l app.kubernetes.io/name=kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          3m41s
my-cluster-kafka-1   1/1     Running   0          6m17s
my-cluster-kafka-2   1/1     Running   0          5m4s
my-cluster-kafka-3   1/1     Running   0          2m30s
```

By default, the new broker will sit there idle, until new partitions are crated and assigned to it. One option to avoid
that is to use the `kafka-reassign-partitions.sh` tool to move existing data when the new broker is ready. We only have
one topic here, but you may have hundreds of them. In that case, you would need a custom procedure to figure out which
replica changes can be done in order to redistribute the load evenly, also considering available disk space and
preferred replicas. The result of this procedure would be a `reassign.json` file describing the desired partition state
for each topic, that we pass to the tool.

```sh
$ krun_kafka
[strimzi@krun-1664115586 kafka]$ bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: ODAdezsITgmRMcFihU9Neg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 1,0,2	Isr: 1,2,0
	Topic: my-topic	Partition: 1	Leader: 0	Replicas: 0,2,1	Isr: 1,2,0
	Topic: my-topic	Partition: 2	Leader: 2	Replicas: 2,1,0	Isr: 1,2,0

[strimzi@krun-1664115586 kafka]$ cat <<EOF >/tmp/reassign.json
{
  "version": 1,
  "partitions": [
    {"topic": "my-topic", "partition": 0, "replicas": [3, 2, 1]},
    {"topic": "my-topic", "partition": 1, "replicas": [2, 1, 3]},
    {"topic": "my-topic", "partition": 2, "replicas": [1, 3, 2]}
  ]
}
EOF

[strimzi@krun-1664115586 kafka]$ bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --throttle 5000000 --execute
Current partition replica assignment

{"version":1,"partitions":[{"topic":"my-topic","partition":0,"replicas":[1,0,2],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":1,"replicas":[0,2,1],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":2,"replicas":[2,1,0],"log_dirs":["any","any","any"]}]}

Save this to use as the --reassignment-json-file option during rollback
Warning: You must run --verify periodically, until the reassignment completes, to ensure the throttle is removed.
The inter-broker throttle limit was set to 5000000 B/s
Successfully started partition reassignments for my-topic-0,my-topic-1,my-topic-2
```

When moving data between brokers, we use the `--throttle` option to limit the inter-broker traffic to 5 MB/s, in order
to avoid any impact on the cluster while moving partitions between brokers. The problem is that it also applies to the
normal partition replication traffic between brokers, so we need to find the right balance which allows to move data in
a reasonable amount of time, but without slowing down the replication too much.

We can start from a safe throttle value and then
use `kafka.server:type=FetcherLagMetrics,name=ConsumerLag,clientId=([-.\w]+),topic=([-.\w]+),partition=([0-9]+)`
metric to observe how far the followers are lagging behind the leader for a given partition. If this lag is growing or
the reassignment is taking too much time, we can re-execute the command with the `--additional` option and an increased
throttle value.

After the reassignment is started, we use the `--verify` option to check the status of the reassignment process and
disable the replication throttling, which otherwise will continue to affect the cluster. When the process is done, we
can check if the topic configuration changes have been applied.

```sh
[strimzi@krun-1664115586 kafka]$ bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --verify
Status of partition reassignment:
Reassignment of partition my-topic-0 is complete.
Reassignment of partition my-topic-1 is complete.
Reassignment of partition my-topic-2 is complete.

Clearing broker-level throttles on brokers 0,1,2,3
Clearing topic-level throttles on topic my-topic

[strimzi@krun-1664115586 kafka]$ bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: ODAdezsITgmRMcFihU9Neg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 3,2,1	Isr: 1,2,3
	Topic: my-topic	Partition: 1	Leader: 2	Replicas: 2,1,3	Isr: 1,2,3
	Topic: my-topic	Partition: 2	Leader: 2	Replicas: 1,3,2	Isr: 1,2,3

[strimzi@krun-1664115586 kafka]$ exit
```

### Example: scaling up the cluster with CC

Let's repeat the cluster scale up example, but this time using Cruise Control, which is supposed to make rebalancing
easier, as it can figure out by itself the required changes, given a set of high level goals (sensible default are
provided).

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, we verify how the topic
partitions are distributed among the available brokers.

```sh
$ kubectl get po -l app.kubernetes.io/name=kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          9m10s
my-cluster-kafka-1   1/1     Running   0          7m47s
my-cluster-kafka-2   1/1     Running   0          6m24s

$ krun_kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: fVMGczk2RWGPZ3HF0grObg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 2,1,0	Isr: 0,1,2
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1,0,2	Isr: 0,1,2
	Topic: my-topic	Partition: 2	Leader: 0	Replicas: 0,2,1	Isr: 0,1,2
```

Now we add one broker, deploy CC by adding the `spec.cruiseControl` section to the Kafka CR and create a rebalance CR
with `mode: add-brokers`. The first rebalance proposal takes some time because the workload model needs to be created
from scratch, then a new one will generated every 15 minutes. When the new broker is ready, we can force the proposal
refresh by using an annotation. Then, we wait for the rebalance to become ready.

```sh
$ kubectl apply -f sessions/007/crs
kafka.kafka.strimzi.io/my-cluster configured
kafkarebalance.kafka.strimzi.io/my-rebalance created

$ kubectl get po -l app.kubernetes.io/name=kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          4m10s
my-cluster-kafka-1   1/1     Running   0          6m40s
my-cluster-kafka-2   1/1     Running   0          5m28s
my-cluster-kafka-3   1/1     Running   0          2m59s

$ kubectl annotate kr add-brokers strimzi.io/rebalance=refresh
kafkarebalance.kafka.strimzi.io/add-brokers annotated

$ kubectl get kr add-brokers -o wide -w
NAME          CLUSTER      PENDINGPROPOSAL   PROPOSALREADY   REBALANCING   READY   NOTREADY
add-brokers   my-cluster   True
add-brokers   my-cluster                     True
```

When the proposal is ready, we can approve it by using another annotation and wait for CC to move partitions ande
replica roles around. When the rebalance is ready, we see that we obtained the same result as the previous example,
without the need to do any complex planning activity.

```sh
$ kubectl annotate kr add-brokers strimzi.io/rebalance=approve
kafkarebalance.kafka.strimzi.io/add-brokers annotated

$ kubectl get kr add-brokers -o wide -w
NAME          CLUSTER      PENDINGPROPOSAL   PROPOSALREADY   REBALANCING   READY   NOTREADY
add-brokers   my-cluster                                     True
add-brokers   my-cluster                                                   True

$ krun_kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: fVMGczk2RWGPZ3HF0grObg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 2	Replicas: 2,1,3	Isr: 1,2,3
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1,3,2	Isr: 1,2,3
	Topic: my-topic	Partition: 2	Leader: 3	Replicas: 3,2,1	Isr: 1,2,3
```
