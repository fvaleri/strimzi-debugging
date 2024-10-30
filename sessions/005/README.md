## Active-passive cluster mirroring

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.

At this point, we can deploy the target cluster and an MM2 instance.
The recommended way of deploying the MM2 is near the target Kafka cluster (same subnet or zone), because the producer overhead is greater than the consumer overhead.

> [!IMPORTANT]
> When source and target clusters run on different namespaces or Kubernetes clusters, you have to copy the source `cluster-ca-cert` in the target namespace where MM2 is running.

```sh
$ for f in sessions/005/install/*.yaml; do sed "s/SOURCE_NS/$NAMESPACE/g; s/TARGET_NS/$NAMESPACE/g" $f | kubectl create -f -; done
kafkanodepool.kafka.strimzi.io/combined created
kafka.kafka.strimzi.io/my-cluster-tgt created
kafkamirrormaker2.kafka.strimzi.io/my-mm2 created
configmap/mirror-maker-2-metrics created
```

When both source and target clusters are up and running, we can start MM2 and check its status.
MM2 runs on top of Kafka Connect with a set of configurable built-in connectors.
The `MirrorSourceConnector` replicates remote topics, ACLs, and configurations of a single source cluster and emits offset syncs.
The `MirrorCheckpointConnector` emits consumer group offsets checkpoints to enable failover points.

```sh
$ kubectl scale kmm2 my-mm2 --replicas 1
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl get po
NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-broker-7                           1/1     Running   0          11m
my-cluster-broker-8                           1/1     Running   0          11m
my-cluster-broker-9                           1/1     Running   0          11m
my-cluster-controller-0                       1/1     Running   0          11m
my-cluster-controller-1                       1/1     Running   0          11m
my-cluster-controller-2                       1/1     Running   0          11m
my-cluster-entity-operator-657b477d4f-sv77v   2/2     Running   0          10m
my-cluster-tgt-combined-0                     1/1     Running   0          6m18s
my-cluster-tgt-combined-1                     1/1     Running   0          6m18s
my-cluster-tgt-combined-2                     1/1     Running   0          6m18s
my-mm2-mirrormaker2-0                         1/1     Running   0          2m5s
strimzi-cluster-operator-d78fd875b-ljmpl      1/1     Running   0          11m

$ kubectl get kmm2 my-mm2 -o yaml | yq .status
conditions:
  - lastTransitionTime: "2024-10-12T10:14:20.521458310Z"
    status: "True"
    type: Ready
connectors:
  - connector:
      state: RUNNING
      worker_id: my-mm2-mirrormaker2-0.my-mm2-mirrormaker2.test.svc:8083
    name: my-cluster->my-cluster-tgt.MirrorCheckpointConnector
    tasks: []
    type: source
  - connector:
      state: RUNNING
      worker_id: my-mm2-mirrormaker2-0.my-mm2-mirrormaker2.test.svc:8083
    name: my-cluster->my-cluster-tgt.MirrorSourceConnector
    tasks:
      - id: 0
        state: RUNNING
        worker_id: my-mm2-mirrormaker2-0.my-mm2-mirrormaker2.test.svc:8083
      - id: 1
        state: RUNNING
        worker_id: my-mm2-mirrormaker2-0.my-mm2-mirrormaker2.test.svc:8083
      - id: 2
        state: RUNNING
        worker_id: my-mm2-mirrormaker2-0.my-mm2-mirrormaker2.test.svc:8083
    type: source
labelSelector: strimzi.io/cluster=my-mm2,strimzi.io/name=my-mm2-mirrormaker2,strimzi.io/kind=KafkaMirrorMaker2
observedGeneration: 2
replicas: 1
url: http://my-mm2-mirrormaker2-api.test.svc:8083
```

Finally, we can send 1 million messages to the test topic in the source Kafka cluster.
After some time, the log end offsets should match on both clusters.

> [!NOTE]  
> This is a controlled experiment, but the actual offsets tend to naturally diverge with time, because each Kafka cluster operates independently.
> This is why we have offset mapping metadata.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
837463 records sent, 167492.6 records/sec (15.97 MB/sec), 1207.8 ms avg latency, 2358.0 ms max latency.
1000000 records sent, 174733.531365 records/sec (16.66 MB/sec), 1202.91 ms avg latency, 2358.00 ms max latency, 1298 ms 50th, 2138 ms 95th, 2266 ms 99th, 2332 ms 99.9th.

$ kubectl-kafka bin/kafka-get-offsets.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --time -1
my-topic:0:353737
my-topic:1:358846
my-topic:2:287417

$ kubectl-kafka bin/kafka-get-offsets.sh --bootstrap-server my-cluster-tgt-kafka-bootstrap:9092 --topic my-topic --time -1
my-topic:0:353737
my-topic:1:358846
my-topic:2:287417
```

## Tuning MM2 for throughput

High-volume message generation, as seen in web activity tracking, can result in a large number of messages.
Additionally, even a source cluster with moderate throughput can create a significant volume of messages when mirroring large amounts of existing data.
In this case MM2 replication is slow even if you have a fast network, because default producers are not optimized for throughput.

Let's run a load test and see how fast we can replicate data with default settings.
By looking at `MirrorSourceConnector` task metrics, we see that we are saturating the producer buffer (default: 16384 bytes), which is a bottleneck.

```sh
$ kubectl scale kmm2 my-mm2 --replicas 0
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 30000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
1040165 records sent, 207825.2 records/sec (19.82 MB/sec), 752.2 ms avg latency, 1588.0 ms max latency.
...
30000000 records sent, 642659.754504 records/sec (61.29 MB/sec), 137.34 ms avg latency, 2517.00 ms max latency, 39 ms 50th, 614 ms 95th, 1474 ms 99th, 2408 ms 99.9th.
```

On my machine, it takes about 10 minutes to get back `NaN` from the following metrics, which means replication completed.

```sh
$ kubectl scale kmm2 my-mm2 --replicas 1
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl exec $(kubectl get po | grep my-mm2 | awk '{print $1}') -- curl -s http://localhost:9404/metrics \
  | grep -e 'kafka_producer_batch_size_avg{clientid="\\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector' \
    -e 'kafka_producer_request_latency_avg{clientid="\\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector'
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\""} 16277.085847267712
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-1\""} 16278.264065335754
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-2\""} 16277.15397200509
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\""} 10.944482877896922
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-1\""} 14.26193724420191
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-2\""} 11.238677867056245
```

We now increase the producer buffer to default value x20 by overriding its configuration.
Every batch will include more data, so the same test should complete in about half of the time or even less.
The request latency increases, but it is still within reasonable bounds.

```sh
$ kubectl get kmm2 my-mm2 -o yaml | yq '.spec.mirrors[0].sourceConnector.config |= ({"producer.override.batch.size": 327680} + .)' | kubectl apply -f -
kafkamirrormaker2.kafka.strimzi.io/my-mm2 configured

$ kubectl scale kmm2 my-mm2 --replicas 0
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 30000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
3402475 records sent, 680495.0 records/sec (64.90 MB/sec), 32.4 ms avg latency, 342.0 ms max latency.
...
30000000 records sent, 923105.326318 records/sec (88.03 MB/sec), 21.94 ms avg latency, 1495.00 ms max latency, 3 ms 50th, 66 ms 95th, 201 ms 99th, 1329 ms 99.9th.
```

On my machine, it now takes about 5 minutes.

```sh
$ kubectl scale kmm2 my-mm2 --replicas 1
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl exec $(kubectl get po | grep my-mm2 | awk '{print $1}') -- curl -s http://localhost:9404/metrics \
  | grep -e 'kafka_producer_batch_size_avg{clientid="\\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector' \
    -e 'kafka_producer_request_latency_avg{clientid="\\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector'
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\""} 140310.91324200912
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-1\""} 143986.90502793295
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-2\""} 122895.43076923076
kafka_producer_batch_size_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-3\""} 33464.164893617024
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\""} 59.678899082568805
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-1\""} 71.0561797752809
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-2\""} 52.08247422680412
kafka_producer_request_latency_avg{clientid="\"connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-3\""} 41.670212765957444
```
