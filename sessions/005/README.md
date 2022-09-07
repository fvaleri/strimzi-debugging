## Disaster recovery strategies and Mirror Maker

In order to create a disaster recovery plan you would need to decide the Recovery Point Objective (RPO), which is the
maximum amount of data you are willing to risk losing, and the Recovery Time Objective (RTO), which is the maximum
amount of downtime that your system can have. Zero RPO requires a good infrastructure, but there are cheaper
alternatives if you can relax this objective. The RTO depends on your tooling and failover procedures, since failing
over applications is not a system responsibility.

A data corruption due to human error or bug would also be replicated, so having periodic backups from which you can
restore the cluster at a specific point in time is a must in every case. One strategy here is to backup the full cluster
configuration (including any custom configuration), while also taking disk/volumes snapshots. Unfortunately, we do not
have an integrated solution for that, so you would need to create some automation scripts for hot cluster backup and
restore. Restoring data in a meaningful way, where you know what you have restored and what you might be missing, is
difficult and a solid monitoring system may help.

Assuming the right replication configuration, the only way to have zero RPO is to setup a stretch Kafka cluster, which
is one that evenly spans multiple data centers (i.e. synchronous replication). Usually only DCs that are close to each
other (i.e. AWS availability zones in the same region) can support the required latency (<100ms). OpenShift supports
stretch/multi-site clusters with some requirements, then you simply deploy Kafka on top of that setting rack awareness.
If you are willing to sacrifice high availability for zero RPO, you can even use two DCs, at the cost of longer RTO (not
recommended).

![](images/stretch.png)

The cheaper alternative to the stretch cluster is Mirror Maker 2 (MM2), where a secondary/backup cluster is continuously
kept in-sync, including consumer group offsets and topic ACLs. Unfortunately, you can't completely avoid duplicates and
data loss because replication is asynchronous with no transactions support (at least once delivery semantics, see
KIP-656). Producers, should be able to re-send data missing on the backup cluster, which means storing the latest
messages sent somewhere. Consumers should be idempotent, in order to tolerate some duplicates (this is good in general).
In case of disaster, the amount of data that may be lost depends on latency metrics of MM2 connectors, so you should
carefully monitor these metrics and set alerts. You would also need virtual hosts or a cluster proxy, so that you can
switch all clients at once from a central place.

![](images/mm2.png)

### MM2 active-passive configuration

In this example, we are going to deploy MM2 on OpenShift with the classic active-passive configuration, where all data
and configuration are only replicated from the source cluster (primary) to the target cluster (backup). For convenience,
we will run the two Kafka clusters in two namespaces on the same OpenShift cluster, but a similar configuration can be
used to replicate data to a backup cluster hosted on a different data center.

[Deploy the Streams operator and Kafka cluster](/sessions/001). This will be our source cluster. Then, we have to create
the target namespace, cluster and MM2. We want to connect securely, so we also need to copy the source cluster CA secret
to the target namespace removing any runtime property, so that it can be trusted by MM2. The recommended way of
deploying the MM2 cluster is near the target Kafka cluster (same subnet or zone), because the overhead on the producer
is usually greater than the consumer.

```
$ kubectl create ns target
namespace/target created

$ EXP="del(.metadata.namespace, .metadata.resourceVersion, .metadata.selfLink, .metadata.uid, .metadata.ownerReferences, .status)" \
  && kubectl get secret "my-cluster-cluster-ca-cert" -o yaml | yq e "$EXP" - | kubectl -n target create -f -
secret/my-cluster-cluster-ca-cert created

$ kubectl -n target create -f sessions/005/crs
kafka.kafka.strimzi.io/my-cluster-tgt created
kafkamirrormaker2.kafka.strimzi.io/my-mm2 created
configmap/mm2-metrics created
```

When the target cluster is up and running, we can start MM2 pod and check its connector status. MM2 runs on top of Kafka
Connect with a set of configurable built-in connectors. The `MirrorSourceConnector` replicates remote topics, ACLs and
configs of a single source cluster and emits offset-syncs to an internal topic. The `MirrorCheckpointConnector` emits
consumer group offsets checkpoints to enable failover points.

```
$ kubectl -n target scale kmm2 my-mm2 --replicas 1
kafkamirrormaker2.kafka.strimzi.io/my-mm2 scaled

$ kubectl -n target get po
NAME                                              READY   STATUS    RESTARTS   AGE
my-cluster-tgt-entity-operator-7647f48d79-9xrbc   3/3     Running   0          11m
my-cluster-tgt-kafka-0                            1/1     Running   0          12m
my-cluster-tgt-kafka-1                            1/1     Running   0          12m
my-cluster-tgt-kafka-2                            1/1     Running   0          12m
my-cluster-tgt-zookeeper-0                        1/1     Running   0          13m
my-cluster-tgt-zookeeper-1                        1/1     Running   0          13m
my-cluster-tgt-zookeeper-2                        1/1     Running   0          13m
my-mm2-mirrormaker2-7c87647dcd-vdftr              1/1     Running   0          2m19s

$ kubectl -n target get kmm2 my-mm2 -o yaml | yq e '.status'
conditions:
  - lastTransitionTime: "2022-09-15T15:42:39.600109Z"
    status: "True"
    type: Ready
connectors:
  - connector:
      state: RUNNING
      worker_id: 10.128.2.65:8083
    name: my-cluster->my-cluster-tgt.MirrorCheckpointConnector
    tasks: []
    type: source
  - connector:
      state: RUNNING
      worker_id: 10.128.2.65:8083
    name: my-cluster->my-cluster-tgt.MirrorSourceConnector
    tasks:
      - id: 0
        state: RUNNING
        worker_id: 10.128.2.65:8083
      - id: 1
        state: RUNNING
        worker_id: 10.128.2.65:8083
    type: source
labelSelector: strimzi.io/cluster=my-mm2,strimzi.io/name=my-mm2-mirrormaker2,strimzi.io/kind=KafkaMirrorMaker2
observedGeneration: 2
replicas: 1
url: http://my-mm2-mirrormaker2-api.target.svc:8083
```

Finally, we can send 1 mln messages to the topic in the source cluster and check if the the log end offsets match on
both clusters after some time. Note that this is a controlled experiment, but the actual offsets tend to naturally
diverge because each cluster operates independently. This is why we have the topic and consumer group offsets mapping
metadata.

```
$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0-5" -- \
    bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 1000000 \
      --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
If you don't see a command prompt, try pressing enter.
1000000 records sent, 201531.640468 records/sec (19.22 MB/sec), 255.97 ms avg latency, 715.00 ms max latency, 185 ms 50th, 627 ms 95th, 687 ms 99th, 704 ms 99.9th.
pod "producer-perf" deleted

$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0" -- \
    bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
      --broker-list my-cluster-kafka-bootstrap:9092 --topic my-topic --time -1
If you don't see a command prompt, try pressing enter.
my-topic:0:353737
my-topic:1:358846
my-topic:2:287417
pod "get-leo" deleted

$ kubectl -n target run get-leo -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0" -- \
    bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
      --broker-list my-cluster-tgt-kafka-bootstrap:9092 --topic my-topic --time -1
If you don't see a command prompt, try pressing enter.
my-topic:0:353737
my-topic:1:358846
my-topic:2:287417
```

Use cases like web activity tracking can generate a high volume of messages. But even a source cluster with moderate
throughput can produce a high volume of messages when having lot of existing data to mirror. In these cases MM2 may be
unable to keep up with incoming data and replication will be slow. This happens because, by default, the
underline `MirrorSourceConnector` producer is not optimized for throughput. Let's do a load test to simulate this and
see how fast we can replicate data with default MM2 settings.

```
$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0-5" -- \
    bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 30000000 \
      --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
If you don't see a command prompt, try pressing enter.
1047156 records sent, 209389.3 records/sec (19.97 MB/sec), 102.5 ms avg latency, 496.0 ms max latency.
...
30000000 records sent, 239285.970664 records/sec (22.82 MB/sec), 15.98 ms avg latency, 496.00 ms max latency, 3 ms 50th, 60 ms 95th, 115 ms 99th, 428 ms 99.9th.
pod "producer-perf" deleted

$ kubectl -n target exec -it $(kubectl -n target get po | grep my-mm2 | awk '{print $1}') -- \
  bin/kafka-run-class.sh kafka.tools.JmxTool --jmx-url service:jmx:rmi:///jndi/rmi://:9999/jmxrmi \
    --date-format yyyy-MM-dd_HH:mm:ss --one-time true --wait \
    --object-name kafka.producer:type=producer-metrics,client-id=\""connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\"" \
    --attributes batch-size-avg,request-latency-avg
2022-09-27_16:36:22,16224.29945722409,3.705901141898906
```

That's not bad, because we are almost saturating the default producer `batch.size` which is 16384 bytes and the latency
is good. If you then check the target topic offsets again, you will see them updating for quite some time time, meaning
that the replication is still going on. Let's try to remove that bottleneck by uncommenting the line
with `producer.override.batch.size` and applying that change (restart not needed). If we repeat the previous test, we
will see that replication is completed much faster because we have increased the `batch.size` by a factor of 20, so
every batch will carry more data (note that a single send request can include multiple batches, each for one specific
partition). We also observe that the request latency has increased significantly, but it is still good. As always with
tuning, there is no free lunch and you need to find the right balance between throughout and latency.

```
$ kubectl -n target apply -f sessions/005/crs
kafka.kafka.strimzi.io/my-cluster-tgt unchanged
kafkamirrormaker2.kafka.strimzi.io/my-mm2 configured
configmap/mm2-metrics unchanged

$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0-5" -- \
    bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 30000000 \
      --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
253179 records sent, 250585.7 records/sec (23.90 MB/sec), 15.5 ms avg latency, 324.0 ms max latency.
...
30000000 records sent, 241625.657423 records/sec (23.04 MB/sec), 9.02 ms avg latency, 324.00 ms max latency, 1 ms 50th, 44 ms 95th, 65 ms 99th, 84 ms 99.9th.

$ kubectl -n target exec -it $(kubectl -n target get po | grep my-mm2 | awk '{print $1}') -- \
  bin/kafka-run-class.sh kafka.tools.JmxTool --jmx-url service:jmx:rmi:///jndi/rmi://:9999/jmxrmi \
    --date-format yyyy-MM-dd_HH:mm:ss --one-time true --wait \
    --object-name kafka.producer:type=producer-metrics,client-id=\""connector-producer-my-cluster->my-cluster-tgt.MirrorSourceConnector-0\"" \
    --attributes batch-size-avg,request-latency-avg
2022-09-27_16:25:19,326751.30785562634,25.189954925949774
```
