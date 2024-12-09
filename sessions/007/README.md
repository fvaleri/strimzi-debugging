## Scaling up the cluster with the reassign tool

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Then, we send some data.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
1000000 records sent, 233699.462491 records/sec (22.29 MB/sec), 866.05 ms avg latency, 1652.00 ms max latency, 827 ms 50th, 1500 ms 95th, 1595 ms 99th, 1614 ms 99.9th.  
```

When the cluster is ready, we want to scale it up and put some load on the new broker, which otherwise will sit idle waiting for new topic creation.
Thanks to the Cluster Operator, we can scale the cluster up by simply raising the number of broker replicas in the Kafka custom resource (CR).

```sh
$ kubectl patch knp kafka --type merge -p '
    spec:
      replicas: 4'
kafkanodepool.kafka.strimzi.io/kafka patched

$ kubectl get po -l app.kubernetes.io/name=kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          2m8s
my-cluster-kafka-1   1/1     Running   0          2m8s
my-cluster-kafka-2   1/1     Running   0          2m8s
my-cluster-kafka-3   1/1     Running   0          30s
```

One option is to use the `kafka-reassign-partitions.sh` tool to move existing data.
We only have one topic here, but you may have hundreds of them, where some of them are busier than others.
You would need a custom procedure to figure out which replica changes can be done in order to improve the balance, also considering available disk space and preferred replicas.
The result of this procedure would be a `reassign.json` file describing the desired partition state for each topic that we can pass to the tool.

```sh
$ kubectl run rebalancing -itq --rm --restart="Never" --image="apache/kafka:$KAFKA_VERSION" -- bash
rebalancing:/$ /opt/kafka/bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: XbszKNVQSSKTPB3sGvRaGg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: my-topic	Partition: 0	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	Topic: my-topic	Partition: 1	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0
	Topic: my-topic	Partition: 2	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2

rebalancing:/$ echo -e '{
  "version": 1,
  "partitions": [
    {"topic": "my-topic", "partition": 0, "replicas": [3, 2, 1]},
    {"topic": "my-topic", "partition": 1, "replicas": [2, 1, 3]},
    {"topic": "my-topic", "partition": 2, "replicas": [1, 3, 2]}
  ]
}' >/tmp/reassign.json

rebalancing:/$ /opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --throttle 10000000 --execute
Current partition replica assignment

{"version":1,"partitions":[{"topic":"my-topic","partition":0,"replicas":[0,2,1],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":1,"replicas":[2,1,0],"log_dirs":["any","any","any"]},{"topic":"my-topic","partition":2,"replicas":[1,0,2],"log_dirs":["any","any","any"]}]}

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
rebalancing:/$ /opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --reassignment-json-file /tmp/reassign.json --verify
Status of partition reassignment:
Reassignment of partition my-topic-0 is completed.
Reassignment of partition my-topic-1 is completed.
Reassignment of partition my-topic-2 is completed.

Clearing broker-level throttles on brokers 0,1,2,3
Clearing topic-level throttles on topic my-topic

rebalancing:/$ /opt/kafka/bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --describe
Topic: my-topic	TopicId: XbszKNVQSSKTPB3sGvRaGg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: my-topic	Partition: 0	Leader: 3	Replicas: 3,2,1	Isr: 2,1,3
	Topic: my-topic	Partition: 1	Leader: 2	Replicas: 2,1,3	Isr: 2,1,3
	Topic: my-topic	Partition: 2	Leader: 1	Replicas: 1,3,2	Isr: 1,2,3

[strimzi@rkc-1664115586 kafka]$ exit
exit
```

## Scaling up the cluster with Cruise Control

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Then, we deploy Cruise Control with the auto rebalance feature enabled.

> [!NOTE]  
> The auto rebalance feature will automatically generate and execute KafkaRebalance resources on cluster scale up and down.
> Each auto rebalance mode can be customized by adding custom KafkaRebalance templates.

The Cluster Operator will trigger a rolling update to add the metrics reporter plugin to brokers, and then it will deploy Cruise Control.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      cruiseControl: 
        autoRebalance:
          - mode: add-brokers
          - mode: remove-brokers'
kafka.kafka.strimzi.io/my-cluster patched
```

When Cruise Control is ready, we send some data and check how the topic partitions are distributed between the brokers.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 10000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
...
10000000 records sent, 165387.668695 records/sec (15.77 MB/sec), 1750.32 ms avg latency, 5498.00 ms max latency, 1504 ms 50th, 3831 ms 95th, 4697 ms 99th, 5377 ms 99.9th.

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic my-topic
Topic: my-topic	TopicId: Gkti6y9fQjiYCU02tkwTFg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,retention.bytes=1073741824
	Topic: my-topic	Partition: 0	Leader: 9	Replicas: 9,7,8	Isr: 7,8,9	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 1	Leader: 7	Replicas: 7,8,9	Isr: 7,8,9	Elr: 	LastKnownElr: 
	Topic: my-topic	Partition: 2	Leader: 8	Replicas: 8,9,7	Isr: 7,8,9	Elr: 	LastKnownElr: 
```

At this point we scale up the Kafka cluster, adding two more brokers.

```sh
$ kubectl patch knp broker --type merge -p '
    spec:
      replicas: 5'
kafkanodepool.kafka.strimzi.io/broker patched
```

After some time, we check if the KafkaRebalance resource is automatically created and executed.

```sh
$ kubectl get kr -w
NAME                                      CLUSTER      TEMPLATE   STATUS
my-cluster-auto-rebalancing-add-brokers   my-cluster              
my-cluster-auto-rebalancing-add-brokers   my-cluster              PendingProposal
my-cluster-auto-rebalancing-add-brokers   my-cluster              ProposalReady
my-cluster-auto-rebalancing-add-brokers   my-cluster              Rebalancing
my-cluster-auto-rebalancing-add-brokers   my-cluster              Ready
```

When the KafkaRebalance is ready, we can see that the new broker contains some of the existing replicas.

```sh
$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic my-topicic
Topic: my-topic	TopicId: Gkti6y9fQjiYCU02tkwTFg	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,retention.bytes=1073741824
    Topic: my-topic Partition: 0    Leader: 9   Replicas: 9,10,11   Isr: 10,9,11    Elr:    LastKnownElr: 
    Topic: my-topic Partition: 1    Leader: 11  Replicas: 11,10,9   Isr: 10,9,11    Elr:    LastKnownElr: 
    Topic: my-topic Partition: 2    Leader: 8   Replicas: 8,9,7     Isr: 7,8,9      Elr:    LastKnownElr: 
```
