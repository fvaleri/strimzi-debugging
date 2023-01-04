# Cruise Control and unbalanced clusters

By default, Kafka try to distribute the load evenly across brokers.
This is achieved through the concept of preferred replica, which is the first replica created for a new topic.
The preferred replica is designated as the partition leader and assigned to a broker so that we have balanced leader distribution.
A background thread moves the leader role to the preferred replica when it is in sync.

This may not be enough, and we may end up with uneven distribution of load across brokers as a consequence of broker failures, addition of new brokers or simply because some partitions are used more than others.
The `kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent` metric is a good overall load metric for Kafka scaling and rebalancing decisions.
Below 70% (i.e. the request handler threads are busy 30% of the time) performance start to degrade, below 50% you start getting into trouble (scaling or rebalancing at this point adds even more load), and if you hit 30% it's barely usable for users.

Rebalancing means moving partitions between brokers (inter brokers), between broker disks (intra broker), or simply change partition leaders to restore the cluster balance.
We can apply partition and leadership movements using the `kafka-reassign-partitions.sh` tool, but the user has to determine the rebalance proposal, which can be tricky and time-consuming.
This is why [Cruise Control](https://github.com/linkedin/cruise-control) (CC) was created.

A replica workload model is periodically updated by the workload monitor using the resource utilization metrics from broker agents (CPU, disk, bytes-in, bytes-out).
The analyzer uses this model to create a valid rebalance proposal when possible (one that must satisfy all configured hard goals, and possibly soft goals).
The executor ensures that there is only one active rebalancing at any given time and applies changes in batches, enabling graceful cancellation.
If two equivalent changes are possible, the one with the lower cost is selected (leadership change > replica move > replica swap).

![](images/cc.png)

As of today, Streams still requires the manual approval of the auto-generated rebalance proposal, but we are working to enable full automation.
In order to have accurate rebalance proposals when using CPU goals, we can set CPU requests equal to CPU limits in `.spec.kafka.resources`.
That way, all CPU resources are reserved upfront (Guaranteed QoS) and CC can properly evaluate CPU utilization when generating the rebalance proposals.

# Example: scaling up the cluster

[Deploy Streams operator and Kafka cluster](/sessions/001).
When the cluster is ready, we want to scale it up and put some load on the new broker, which otherwise will sit idle waiting for new topic creations.
Thanks to the CO, we can scale the cluster up by simply raising the number of broker replicas in the Kafka CR.

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

One option to put some load on the new broker is to use the `kafka-reassign-partitions.sh` tool to move existing data.
We only have one topic here, but you may have hundreds of them, where some of them are busier than others.
You would need a custom procedure to figure out which replica changes can be done in order to improve the balance, also considering available disk space and preferred replicas.
The result of this procedure would be a `reassign.json` file describing the desired partition state for each topic that we can pass to the tool.

```sh
$ kubectl run rebalancing -itq --rm --restart="Never" --image="$INIT_STRIMZI_IMAGE" -- bash
[strimzi@krun-1664115586 kafka]$ bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: odTuFAweSkSLsboC-QQ4wg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
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

We use the `--throttle` option to limit the inter-broker traffic to 5 MB/s, in order to avoid any impact on the cluster while moving partitions between brokers.
The problem is that it also applies to the normal replication traffic between brokers, so we need to find the right balance which allows to move data in a reasonable amount of time, but without slowing down the replication too much.

We can start from a safe throttle value and then use `kafka.server:type=FetcherLagMetrics,name=ConsumerLag,clientId=([-.\w]+),topic=([-.\w]+),partition=([0-9]+)` metric to observe how far the followers are lagging behind the leader for a given partition. 
If this lag is growing or the reassignment is taking too much time, we can re-execute the command with the `--additional` option, increasing the throttle value.

After the reassignment is started, we use `--verify` option to check the status of the reassignment process and disable the replication throttling, which otherwise will continue to affect the cluster.
When the process is done, we can check if the topic configuration changes have been applied.

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
Topic: my-topic	TopicId: odTuFAweSkSLsboC-QQ4wg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 3	Replicas: 3,2,1	Isr: 1,2,3
	Topic: my-topic	Partition: 1	Leader: 2	Replicas: 2,1,3	Isr: 1,2,3
	Topic: my-topic	Partition: 2	Leader: 1	Replicas: 1,3,2	Isr: 1,2,3

[strimzi@krun-1664115586 kafka]$ exit
exit
```

# Example: scaling up the cluster with CC

Let's repeat the cluster scale up example, but this time using Cruise Control to see how it helps with the planning phase.
CC can figure out by itself the required changes, given a set of high level goals (sensible default are provided).

[Deploy Streams operator and Kafka cluster](/sessions/001).
When the cluster is ready, we verify how the topic partitions are distributed between the available brokers.
Then we add one broker, deploy CC by adding the `.spec.cruiseControl` section to the Kafka CR and create a rebalance CR with `mode: add-brokers`.

```sh
$ krun kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: n1QKre80QFmnEKWIXfrLDw	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
	Topic: my-topic	Partition: 2	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	
$ kubectl apply -f sessions/007/resources
kafka.kafka.strimzi.io/my-cluster configured
kafkarebalance.kafka.strimzi.io/my-rebalance created

$ kubectl get po -l app.kubernetes.io/name=kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          3m41s
my-cluster-kafka-1   1/1     Running   0          6m17s
my-cluster-kafka-2   1/1     Running   0          5m4s
my-cluster-kafka-3   1/1     Running   0          2m30s
```

The first rebalance proposal generation takes some time because the workload model is created from scratch, then it will be automatically refreshed every 15 minutes.
Before moving on, wait for the proposal to become ready.

```sh
$ kubectl get kr add-brokers -o wide -w
NAME          CLUSTER      PENDINGPROPOSAL   PROPOSALREADY   REBALANCING   READY   NOTREADY
add-brokers   my-cluster   True                                                    
add-brokers   my-cluster                     True                                  

$ kubectl get kr add-brokers -o yaml | yq '.status'
conditions:
  - lastTransitionTime: "2022-10-29T09:55:40.352012Z"
    status: "True"
    type: ProposalReady
observedGeneration: 1
optimizationResult:
  afterBeforeLoadConfigMap: add-brokers
  dataToMoveMB: 0
  excludedBrokersForLeadership: []
  excludedBrokersForReplicaMove: []
  excludedTopics: []
  intraBrokerDataToMoveMB: 0
  monitoredPartitionsPercentage: 100
  numIntraBrokerReplicaMovements: 0
  numLeaderMovements: 0
  numReplicaMovements: 44
  onDemandBalancednessScoreAfter: 80.87946050436929
  onDemandBalancednessScoreBefore: 76.41773549482696
  provisionRecommendation: ""
  provisionStatus: RIGHT_SIZED
  recentWindows: 1
sessionId: f0605d40-37be-43b9-be1f-83167633f37c
```

When the proposal is ready, we can approve it by using another annotation and wait for CC to move partitions ande replica roles around.
When the rebalance is ready, we can look at the result and see if the new broker has picked some of the existing partitions.

```sh
$ kubectl annotate kr add-brokers strimzi.io/rebalance=approve
kafkarebalance.kafka.strimzi.io/add-brokers annotated

$ kubectl get kr add-brokers -o wide -w
NAME          CLUSTER      PENDINGPROPOSAL   PROPOSALREADY   REBALANCING   READY   NOTREADY
add-brokers   my-cluster                                     True
add-brokers   my-cluster                                                   True

$ krun kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: n1QKre80QFmnEKWIXfrLDw	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 2	Replicas: 2,1,3	Isr: 2,1,3
	Topic: my-topic	Partition: 1	Leader: 1	Replicas: 1,3,2	Isr: 2,1,3
	Topic: my-topic	Partition: 2	Leader: 0	Replicas: 0,2,3	Isr: 0,2,3
```
