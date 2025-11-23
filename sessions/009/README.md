## Scaling Up the Cluster with the Reassign Tool

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Next, send test data to the cluster.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
1000000 records sent, 233699.462491 records/sec (22.29 MB/sec), 866.05 ms avg latency, 1652.00 ms max latency, 827 ms 50th, 1500 ms 95th, 1595 ms 99th, 1614 ms 99.9th.  
```

Once the cluster is ready, scale it up and distribute load to the new broker, which would otherwise remain idle awaiting new topic creation.
The Cluster Operator makes scaling straightforward by increasing the broker replica count in the Kafka custom resource (CR).

```sh
$ kubectl patch knp broker --type merge -p '
    spec:
      replicas: 4'
kafkanodepool.kafka.strimzi.io/broker patched

$ kubectl get po -l app.kubernetes.io/name=broker
NAME                   READY   STATUS    RESTARTS   AGE
my-cluster-broker-10   1/1     Running   0          2m8s
my-cluster-broker-11   1/1     Running   0          2m8s
my-cluster-broker-12   1/1     Running   0          2m8s
my-cluster-broker-13   1/1     Running   0          30s
```

One approach uses the `kafka-reassign-partitions.sh` tool to move existing data.
While this example has one topic, production environments often have hundreds with varying load patterns.
A custom procedure is needed to determine optimal replica placement, considering factors like broker load, disk space, and preferred replicas.
This analysis produces a `reassign.json` file describing the target partition distribution for the tool to execute.

```sh
$ kubectl exec -it my-cluster-broker-10 -- bash
[kafka@my-cluster-broker-10 kafka]$ /opt/kafka/bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: XbszKNVQSSKTPB3sGvRaGg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: my-topic	Partition: 0	Leader: 10	Replicas: 10,12,11	Isr: 10,12,11
	Topic: my-topic	Partition: 1	Leader: 12	Replicas: 12,11,10	Isr: 12,11,10
	Topic: my-topic	Partition: 2	Leader: 11	Replicas: 11,10,12	Isr: 11,10,12

[kafka@my-cluster-broker-10 kafka]$ cat <<EOF >/tmp/reassign.json
{
  "version": 1,
  "partitions": [
    {"topic": "my-topic", "partition": 0, "replicas": [13, 12, 11]},
    {"topic": "my-topic", "partition": 1, "replicas": [12, 11, 13]},
    {"topic": "my-topic", "partition": 2, "replicas": [11, 13, 12]}
  ]
}
EOF

[kafka@my-cluster-broker-10 kafka]$ /opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --throttle 10000000 --execute
Current partition replica assignment

{"version":1,"partitions":[{"topic":"my-topic","partition":0,"replicas":[10,12,11],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":1,"replicas":[12,11,10],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":2,"replicas":[11,10,12],"log_dirs":["any","any","any"]}]}

Save this to use as the --reassignment-json-file option during rollback
Warning: You must run --verify periodically, until the reassignment completes, to ensure the throttle is removed.
The inter-broker throttle limit was set to 10000000 B/s
Successfully started partition reassignments for my-topic-0,my-topic-1,my-topic-2
```

To minimize cluster impact during partition movement, use the `--throttle` option with a 10 MB/s limit.

> [!IMPORTANT]
> The `--throttle` option affects all replication traffic between brokers, not just reassignment operations.
> Balance the throttle value to move data in reasonable time without degrading normal replication.
> Always run `--verify` after completion to remove throttling, which persists until explicitly disabled.

Start with a conservative throttle value, then monitor the `kafka.server:type=FetcherLagMetrics,name=ConsumerLag,clientId=([-.\w]+),topic=([-.\w]+),partition=([0-9]+)` metric to track follower lag for each partition.
If lag grows or reassignment progresses slowly, increase the throttle by running the command again with the `--additional` option.

After starting reassignment, use the `--verify` option to monitor progress and disable replication throttling.
Once complete, verify that the topic configuration changes were applied successfully.

```sh
[kafka@my-cluster-broker-10 kafka]$ /opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --verify
Status of partition reassignment:
Reassignment of partition my-topic-0 is completed.
Reassignment of partition my-topic-1 is completed.
Reassignment of partition my-topic-2 is completed.

Clearing broker-level throttles on brokers 10,11,12,13
Clearing topic-level throttles on topic my-topic

[kafka@my-cluster-broker-10 kafka]$ /opt/kafka/bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: XbszKNVQSSKTPB3sGvRaGg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: my-topic	Partition: 0	Leader: 13	Replicas: 13,12,11	Isr: 12,11,13
	Topic: my-topic	Partition: 1	Leader: 12	Replicas: 12,11,13	Isr: 12,11,13
	Topic: my-topic	Partition: 2	Leader: 11	Replicas: 11,13,12	Isr: 11,12,13

[kafka@my-cluster-broker-10 kafka]$ exit
exit
```

## Scaling Up the Cluster with Cruise Control

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Once the cluster is ready, send test data and examine the partition distribution across brokers.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 10000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
...
10000000 records sent, 435085.3 records/sec (41.49 MB/sec), 521.45 ms avg latency, 9808.00 ms max latency, 258 ms 50th, 1399 ms 95th, 9636 ms 99th, 9781 ms 99.9th.

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic my-topic
Topic: my-topic	TopicId: w7uEJVDXSm22zscX2-9AYA	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 11	Replicas: 11,12,10	Isr: 11,12,10	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 1	Leader: 12	Replicas: 12,10,11	Isr: 12,11,10	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 2	Leader: 11	Replicas: 10,11,12	Isr: 11,12,10	Elr: 	LastKnownElr: 
```

Next, deploy Cruise Control with auto-rebalancing enabled.

> [!NOTE]
> Auto-rebalancing automatically generates and executes KafkaRebalance resources during cluster scaling operations.
> Each mode supports customization through KafkaRebalance templates.

The Cluster Operator performs a rolling update to add the metrics reporter to brokers, then deploys Cruise Control.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      cruiseControl: 
        autoRebalance:
          - mode: add-brokers
          - mode: remove-brokers'
kafka.kafka.strimzi.io/my-cluster patched
```

Allow Cruise Control time to build its internal workload model before scaling up the Kafka cluster by adding a new broker.

```sh
$ kubectl patch knp broker --type merge -p '
    spec:
      replicas: 4'
kafkanodepool.kafka.strimzi.io/broker patched
```

Monitor KafkaRebalance execution from the command line.

```sh
$ kubectl get kr -w
NAME                                      CLUSTER      TEMPLATE   STATUS     
my-cluster-auto-rebalancing-add-brokers   my-cluster              PendingProposal
my-cluster-auto-rebalancing-add-brokers   my-cluster              ProposalReady
my-cluster-auto-rebalancing-add-brokers   my-cluster              Rebalancing
my-cluster-auto-rebalancing-add-brokers   my-cluster              Ready
```

After KafkaRebalance completes, verify that the new broker now hosts existing replicas.

```sh
$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic my-topic
Topic: my-topic	TopicId: w7uEJVDXSm22zscX2-9AYA	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 11	Replicas: 11,12,10	Isr: 10,11,12	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 1	Leader: 12	Replicas: 12,10,11	Isr: 10,11,12	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 2	Leader: 10	Replicas: 10,11,13	Isr: 10,11,13	Elr: 	LastKnownElr: 
```
