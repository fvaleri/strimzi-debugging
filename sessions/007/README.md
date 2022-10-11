## Cruise Control and unbalanced clusters

By default, Kafka try to distribute the load evenly across brokers. This is achieved through the concept of **preferred
replica**, which is the first replica created for a new topic. This is designated as the leader and assigned to a broker
in order to balance leader distribution. A background thread moves leader to preferred replica when it is in sync.

Sometimes, this may not be enough and we may end up with **uneven distribution of load across brokers** as a consequence
of some broker failures, the addition of new brokers or simply because some partitions are used more than others.
The `RequestHandlerAvgIdlePercent` broker metric is a good overall load measurement metric for Kafka scaling decisions.
Good rule of thumb is when it hits 20% (i.e. the request handler threads are busy 80% of the time), then it's time to
plan your cluster expansion, at 10% you need to scale it now.

**Rebalancing** means moving partitions between brokers (inter brokers), between disks on the same broker
(intra broker), or simply change leaders in order to restore the balance. Usually we need some combination of partition
movements and leadership changes. When using `kafka-reassign-partitions.sh` for rebalancing, the task of figuring out
which changes are required and possible is left to the user. This requires some calculations that may be hard and time
consuming, especially on big clusters with lots of partitions. Automating this complex task is the reason
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

### Example: reduce the topic replication factor

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, let's try to reduce the topic
replication factor by editing its specification. As you can see, the TO does not allow this change.

```sh
$ kubectl patch kt my-topic --type merge -p '
    spec:
      replicas: 2'
kafkatopic.kafka.strimzi.io/my-topic patched

$ kubectl get kt my-topic -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T14:21:59.887479Z"
    message: Changing 'spec.replicas' is not supported. This KafkaTopic's 'spec.replicas' should be reverted to 3 and then the replication should be changed directly in Kafka.
    reason: ReplicationFactorChangeException
    status: "True"
    type: NotReady
observedGeneration: 5
topicName: my-topic
```

As a workaround, we can use the reassign tool to apply the above change at Kafka level. The preferred replica is the
first one that appears in the replicas list. In `reassign.json` we distribute them evenly among available brokers. Note
that we are also throttling the movement of partitions to 5 MB/s to avoid disrupting other clients. If the partition
movement is too slow, you can resubmit the execute command with the `--additional` option and a new throttle value.

```sh
$ krun_kafka
[strimzi@krun-1664115586 kafka]$ bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: 3n2nu6v9SS23xALR8yHADA	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
	Topic: my-topic	Partition: 1	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	Topic: my-topic	Partition: 2	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0

[strimzi@krun-1664115586 kafka]$ cat <<EOF >/tmp/reassign.json
{
  "version": 1,
  "partitions": [
    {"topic": "my-topic", "partition": 0, "replicas": [0, 1]},
    {"topic": "my-topic", "partition": 1, "replicas": [1, 2]},
    {"topic": "my-topic", "partition": 2, "replicas": [2, 0]}
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

The old partitions will be only removed once the reassignment process is complete, so make sure that there is enough
disk space to accommodate for this extra storage requirement. If the process completed successfully, we can check the
topic configuration again.

```sh
[strimzi@krun-1664115586 kafka]$ bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --verify
Status of partition reassignment:
Reassignment of partition my-topic-0 is complete.
Reassignment of partition my-topic-1 is complete.
Reassignment of partition my-topic-2 is complete.

Clearing broker-level throttles on brokers 0,1,2
Clearing topic-level throttles on topic my-topic

[strimzi@krun-1664115586 kafka]$ bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: 3n2nu6v9SS23xALR8yHADA	PartitionCount: 3	ReplicationFactor: 2	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 1	Replicas: 0,1	Isr: 1,0
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1,2	Isr: 2,1
	Topic: my-topic	Partition: 2	Leader: 2	Replicas: 2,0	Isr: 2,0

[strimzi@krun-1664115586 kafka]$ exit

$ kubectl get kt my-topic -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T14:38:59.844320Z"
    status: "True"
    type: Ready
observedGeneration: 6
topicName: my-topic
```

### Example: Cruise Control in action

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, add the `spec.cruiseControl`
to Kafka CR and create a rebalance CR with default goals. Al Kafka pods will be rolled in order to add the required
metric agents, and a CC instance will be started. A new rebalance proposal is created every 15 minutes based on the
latest workload model.

```sh
$ kubectl apply -f sessions/007/crs
kafka.kafka.strimzi.io/my-cluster configured
kafkarebalance.kafka.strimzi.io/my-rebalance created

$ kubectl get po
NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-cruise-control-6f9d8dfc4f-xzhbg    2/2     Running   0          97s
my-cluster-entity-operator-6b68959588-62cvr   3/3     Running   0          6m58s
my-cluster-kafka-0                            1/1     Running   0          2m59s
my-cluster-kafka-1                            1/1     Running   0          5m40s
my-cluster-kafka-2                            1/1     Running   0          4m25s
my-cluster-zookeeper-0                        1/1     Running   0          10m
my-cluster-zookeeper-1                        1/1     Running   0          10m
my-cluster-zookeeper-2                        1/1     Running   0          10m

$ kubectl get kr my-rebalance -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T15:58:41.530923Z"
    status: "True"
    type: PendingProposal
observedGeneration: 1

$ kubectl get kr my-rebalance -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T16:00:29.244565Z"
    status: "True"
    type: ProposalReady
observedGeneration: 1
optimizationResult:
  afterBeforeLoadConfigMap: my-rebalance
  dataToMoveMB: 0
  excludedBrokersForLeadership: []
  excludedBrokersForReplicaMove: []
  excludedTopics: []
  intraBrokerDataToMoveMB: 0
  monitoredPartitionsPercentage: 100
  numIntraBrokerReplicaMovements: 0
  numLeaderMovements: 37
  numReplicaMovements: 0
  onDemandBalancednessScoreAfter: 94.94004939398923
  onDemandBalancednessScoreBefore: 90.0004242279531
  provisionRecommendation: ""
  provisionStatus: RIGHT_SIZED
  recentWindows: 1
sessionId: c0d1e77e-9b0d-4871-ab30-6443b123307e
```

Let's check the log end offsets of the test topic partitions. Now we send some messages in order to create some
imbalance and see if this is reflected in the auto generated reassignment proposal. We don't want to wait the periodic
proposal creation, so we use the refresh annotation.

```sh
$ krun_kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
1000000 records sent, 201126.307321 records/sec (19.18 MB/sec), 67.85 ms avg latency, 347.00 ms max latency, 44 ms 50th, 248 ms 95th, 302 ms 99th, 338 ms 99.9th.
pod "client-1664122756" deleted

$ kubectl annotate kr my-rebalance strimzi.io/rebalance=refresh
kafkarebalance.kafka.strimzi.io/my-rebalance annotated

$ kubectl get kr my-rebalance -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T16:22:06.342700Z"
    status: "True"
    type: ProposalReady
observedGeneration: 1
optimizationResult:
  afterBeforeLoadConfigMap: my-rebalance
  dataToMoveMB: 0
  excludedBrokersForLeadership: []
  excludedBrokersForReplicaMove: []
  excludedTopics: []
  intraBrokerDataToMoveMB: 0
  monitoredPartitionsPercentage: 100
  numIntraBrokerReplicaMovements: 0
  numLeaderMovements: 21
  numReplicaMovements: 18
  onDemandBalancednessScoreAfter: 90.68937677858641
  onDemandBalancednessScoreBefore: 87.91899658253526
  provisionRecommendation: ""
  provisionStatus: RIGHT_SIZED
  recentWindows: 1
sessionId: dd6247d4-ccff-4f90-9581-65bf032df115
```

All good, so let's finally approve the auto generated rebalance proposal so that it can be executed.

```sh
$ kubectl annotate kr my-rebalance strimzi.io/rebalance=approve
kafkarebalance.kafka.strimzi.io/my-rebalance annotated

$ kubectl get kr my-rebalance -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-25T16:24:30.796009Z"
    status: "True"
    type: Ready
observedGeneration: 1
optimizationResult:
  afterBeforeLoadConfigMap: my-rebalance
  dataToMoveMB: 0
  excludedBrokersForLeadership: []
  excludedBrokersForReplicaMove: []
  excludedTopics: []
  intraBrokerDataToMoveMB: 0
  monitoredPartitionsPercentage: 100
  numIntraBrokerReplicaMovements: 0
  numLeaderMovements: 21
  numReplicaMovements: 18
  onDemandBalancednessScoreAfter: 90.68937677858641
  onDemandBalancednessScoreBefore: 87.91899658253526
  provisionRecommendation: ""
  provisionStatus: RIGHT_SIZED
  recentWindows: 1
```
