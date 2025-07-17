## Scaling up the cluster with the reassign tool

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Then, we send some data.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
1000000 records sent, 233699.462491 records/sec (22.29 MB/sec), 866.05 ms avg latency, 1652.00 ms max latency, 827 ms 50th, 1500 ms 95th, 1595 ms 99th, 1614 ms 99.9th.  
```

When the cluster is ready, we want to scale it up and put some load on the new broker, which otherwise will sit idle waiting for new topic creation.
Thanks to the Cluster Operator, we can scale the cluster up by simply raising the number of broker replicas in the Kafka custom resource (CR).

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

One option is to use the `kafka-reassign-partitions.sh` tool to move existing data.
We only have one topic here, but you may have hundreds of them, where some of them are busier than others.
You would need a custom procedure to figure out which replica changes can be done in order to improve the balance, also considering available disk space and preferred replicas.
The result of this procedure would be a `reassign.json` file describing the desired partition state for each topic that we can pass to the tool.

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

To prevent any impact on the cluster while moving partitions between brokers, we use the `--throttle` option with a limit of 10 MB/s.

> [!IMPORTANT]  
> The `--throttle` option also applies throttling to the normal replication traffic between brokers.
> We need to find the right balance to ensure that we can move data in a reasonable amount of time without slowing down replication too much.
> Don't forget to call `--verify` at the end to disable replication throttling, which otherwise will continue to affect the cluster.

We can start from a safe throttle value and then use the `kafka.server:type=FetcherLagMetrics,name=ConsumerLag,clientId=([-.\w]+),topic=([-.\w]+),partition=([0-9]+)` metric to observe how far the followers are lagging behind the leader for a given partition. 
If this lag is growing or the reassignment is taking too much time, we can run the command again with the `--additional` option to increase the throttle value.

After the reassignment is started, we use the `--verify` option to check the status of the reassignment process and disable the replication throttling.
When the process is done, we can check if the topic configuration changes have been applied.

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

## Scaling up the cluster with Cruise Control

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

When the cluster is ready, we send some data and check how partitions are distributed between the brokers.

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

Then, we deploy Cruise Control with the auto-rebalancing feature enabled.

> [!NOTE]  
> The auto-rebalancing feature will automatically generate and execute KafkaRebalance resources on cluster scale up and down.
> Each mode can be customized by adding custom KafkaRebalance templates.

The Cluster Operator will trigger a rolling update of the brokers to add the metrics reporter, and then it will deploy Cruise Control.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      cruiseControl: 
        autoRebalance:
          - mode: add-brokers
          - mode: remove-brokers'
kafka.kafka.strimzi.io/my-cluster patched
```

Wait some time for Cruise Control to build its internal workload model, and then scale up the Kafka cluster adding a new broker.

```sh
$ kubectl patch knp broker --type merge -p '
    spec:
      replicas: 4'
kafkanodepool.kafka.strimzi.io/broker patched
```

Follow the KafkaRebalance execution from command line.

```sh
$ kubectl get kr -w
NAME                                      CLUSTER      TEMPLATE   STATUS     
my-cluster-auto-rebalancing-add-brokers   my-cluster              PendingProposal
my-cluster-auto-rebalancing-add-brokers   my-cluster              ProposalReady
my-cluster-auto-rebalancing-add-brokers   my-cluster              Rebalancing
my-cluster-auto-rebalancing-add-brokers   my-cluster              Ready
```

When KafkaRebalance is ready, we can see that the new broker now contains existing replicas.

```sh
$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic my-topic
Topic: my-topic	TopicId: w7uEJVDXSm22zscX2-9AYA	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 11	Replicas: 11,12,10	Isr: 10,11,12	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 1	Leader: 12	Replicas: 12,10,11	Isr: 10,11,12	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 2	Leader: 10	Replicas: 10,11,13	Isr: 10,11,13	Elr: 	LastKnownElr: 
```
