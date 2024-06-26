## Storage requirements and recovery

Kafka and ZooKeeper require low-latency storage.
The recommended storage type is block storage (e.g. SSD, NVMe, AWS EBS), as it offers superior efficiency and faster performance compared to file and object storage types.
However, Kafka doesn't directly utilize raw block devices; instead, it writes data to segment files stored on a standard file system (e.g. XFS).
These segment files are memory-mapped for enhanced performance, enabling zero-copy optimization when TLS is not configured.
NFS is not supported due to issues it causes when renaming files.

While disk isn't used when both producer and consumer operations are swift, it becomes necessary when accessing old data or when the Operating System needs to flush dirty pages.
For systems with end-to-end message latency requirements, disk speed and latency, including tail latencies, are crucial factors.
An easy optimization is to disable the last access time file attribute (noatime) to prevent unnecessary disk I/O operations.

Kafka and Zookeeper feature built-in data replication, obviating the need for replicated storage, which would only introduce network overhead.
Kafka supports JBOD (just a bunch of disks), providing flexibility in storage resizing and optimal performance when using multiple disks.
Before removing a disk with JBOD, data migration to other disks is necessary, and Cruise Control can make this task easy.

For optimal topic creation, the retention policy should be set based on storage size, expected throughput, and required retention time.
Storage capacity estimation can be calculated based on message write rate and retention policy:

- Time-based storage capacity (MB) = retention_sec * topic_write_rate (MB/s) * replication_factor
- Size-based storage capacity (MB) = retention_mb * replication_factor

A Kafka topic consists of one or more partitions, where each partition is stored as a set of segment files on the same disk.
Segments become inactive and eligible for deletion or compaction based on `segment.ms` or `segment.bytes` configurations.
It's recommended to set both `retention.ms` and `retention.bytes` to avoid retaining entire segments because of few unexpired records.
Deletion and compaction of segments happen asynchronously, with timing dependent on cluster load and available threads.

Common causes for running out of disk space are invalid retention configurations, cluster imbalance, sudden increase in incoming traffic, malfunctioning applications.
When a log directory becomes full, the broker may terminate forcefully and fail to restart due to insufficient space for log recovery and topic synchronization.
To mitigate this risk, per-broker quotas can be enforced to control client resource usage, and tiered storage can be utilized to offload old data to remote storage.
However, expertise is required to ensure timely archival from local to remote storage.

In Kubernetes, PersistentVolume (PV) is an abstraction for container storage, which is a cluster-wide resource.
A PV ca be requested using a PersistentVolumeClaim (PVC), which is a namespaced resource.
In case of dynamic storage allocation, you can specify a StorageClass (SC), which represents a quality-of-service level.

To ensure that you can recover from a PV if the namespace or PVC is deleted unintentionally, the reclaim policy must be reset from Delete to Retain in the PV specification using the persistentVolumeReclaimPolicy property.
PVs can also inherit the reclaim policy of the associated SC.

Access modes:

- ReadWriteOnce (RWO): the volume can be mounted as read-write by a single node, but allows multiple pods to access when they are running on the same node
- ReadOnlyMany (ROM): the volume can be mounted as read-only by many nodes
- ReadWriteMany (RWM): the volume can be mounted as read-write by many nodes
- ReadWriteOncePod (RWOP): the volume can be mounted as read-write by a single Pod

<br>

---
### Example: avoid running out of Kafka disk space using the Strimzi quota plugin

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.storage.size = \"100Mi\"" \
  | kubectl create -f - \
  && kubectl create -f sessions/001/resources/001-my-topic.yaml
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-1885c206-4577-44c7-86a8-233226c0bf0e   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            59s
pvc-4adcb989-4e40-45cd-9817-ee8c0498ba7d   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            59s
pvc-8dffa283-4dba-4cbf-ad84-8cb2f2524983   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            59s
```

Only network bandwidth and request rate quotas are supported by the default Kafka quota plugin. 
Instead, the [Strimzi quota plugin](https://github.com/strimzi/kafka-quotas-plugin) allows to set storage limits independent of the number of clients.
**When using JBOD, the limit applies across all disks, so you can still fill up one disk while the others may be almost empty.**

The Strimzi Kafka images already contains this plugin.
With the following configuration, all clients will be throttled to 0 when any volume in the cluster has <= 30MiB available bytes.
The check interval is set to 5 seconds.

```sh
$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      config:
        client.quota.callback.class: io.strimzi.kafka.quotas.StaticQuotaCallback
        client.quota.callback.static.kafka.admin.bootstrap.servers: my-cluster-kafka-bootstrap:9092
        client.quota.callback.static.storage.check-interval: 5
        client.quota.callback.static.storage.soft: 73400320
        client.quota.callback.static.storage.hard: 73400320'
```

When the cluster is ready, we try to break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
4129 records sent, 824.2 records/sec (0.79 MB/sec), 2762.9 ms avg latency, 4613.0 ms max latency.
4912 records sent, 980.2 records/sec (0.93 MB/sec), 6737.8 ms avg latency, 9550.0 ms max latency.
5600 records sent, 1117.5 records/sec (1.07 MB/sec), 10297.0 ms avg latency, 14185.0 ms max latency.
...
[2024-03-11 10:56:38,697] WARN [Producer clientId=perf-producer-client] Got error produce response with correlation id 4236 on topic-partition my-topic-2, retrying (2147483646 attempts left). Error: REQUEST_TIMED_OUT. Error Message: Disconnected from node 2 due to timeout (org.apache.kafka.clients.producer.internals.Sender)
[2024-03-11 10:56:38,697] WARN [Producer clientId=perf-producer-client] Got error produce response with correlation id 4338 on topic-partition my-topic-0, retrying (2147483646 attempts left). Error: REQUEST_TIMED_OUT. Error Message: Disconnected from node 2 due to timeout (org.apache.kafka.clients.producer.internals.Sender)
[2024-03-11 10:56:38,697] WARN [Producer clientId=perf-producer-client] Got error produce response with correlation id 4338 on topic-partition my-topic-2, retrying (2147483646 attempts left). Error: REQUEST_TIMED_OUT. Error Message: Disconnected from node 2 due to timeout (org.apache.kafka.clients.producer.internals.Sender)
^C
```

At some point, the perf client can't send data anymore, but the cluster is still healthy.

```sh
$ kubectl exec my-cluster-kafka-0 -- df -h | grep /var/lib/kafka/data \
  && kubectl exec my-cluster-kafka-1 -- df -h | grep /var/lib/kafka/data \
  && kubectl exec my-cluster-kafka-2 -- df -h | grep /var/lib/kafka/data
/dev/rbd2        89M   72M   15M  83% /var/lib/kafka/data
/dev/rbd3        89M   72M   15M  83% /var/lib/kafka/data
/dev/rbd1        89M   72M   15M  83% /var/lib/kafka/data
```

<br>

---
### Example: online Kafka volume recovery using expansion support

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.storage.size = \"100Mi\"" \
  | kubectl create -f - \
  && kubectl create -f sessions/001/resources/001-my-topic.yaml
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-4bfda7c0-0613-4b29-acad-a53627af6406   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            118s
pvc-8648e0ea-c995-4cf8-8cc4-aaaaf207b443   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            118s
pvc-ac74c7cf-291a-474f-a691-f5d09513ec11   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            118s
```

When the cluster is ready, we break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
6497 records sent, 1296.0 records/sec (1.24 MB/sec), 2479.4 ms avg latency, 4609.0 ms max latency.
12256 records sent, 2443.9 records/sec (2.33 MB/sec), 6940.7 ms avg latency, 9567.0 ms max latency.
14944 records sent, 2987.0 records/sec (2.85 MB/sec), 11662.5 ms avg latency, 14529.0 ms max latency
...
[2024-03-04 08:19:07,027] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.135.0.26:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-04 08:19:07,334] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.132.2.20:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-04 08:19:07,428] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.134.0.19:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po | grep my-cluster-kafka
my-cluster-kafka-0                           0/1     CrashLoopBackOff   2 (15s ago)   3m42s
my-cluster-kafka-1                           0/1     CrashLoopBackOff   2 (19s ago)   3m42s
my-cluster-kafka-2                           0/1     CrashLoopBackOff   2 (21s ago)   3m42s

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
If volume expansion is supported on the storage class, you can simply increase the storage size in the Kafka resource, and the operator will take care of it. 
Note that the expansion operation may take some time to complete, depending on the size of the volume and the available resources in the cluster.

```sh
if [[ $(kubectl get sc $(kubectl get pv | grep data-my-cluster-kafka-0 | awk '{print $7}') -o yaml | yq .allowVolumeExpansion) == "true" ]]; then 
  kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        storage:
          size: 20Gi'
fi
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl logs $(kubectl get po | grep cluster-operator | awk '{print $1}') | grep "Resizing"
2024-03-04 08:25:04 INFO  PvcReconciler:140 - Reconciliation #87(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-0 from 100 to 20Gi.
2024-03-04 08:25:04 INFO  PvcReconciler:140 - Reconciliation #87(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-1 from 100 to 20Gi.
2024-03-04 08:25:04 INFO  PvcReconciler:140 - Reconciliation #87(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-2 from 100 to 20Gi.

$ kubectl get pv | grep my-cluster-kafka
pvc-4bfda7c0-0613-4b29-acad-a53627af6406   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            10m
pvc-8648e0ea-c995-4cf8-8cc4-aaaaf207b443   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            10m
pvc-ac74c7cf-291a-474f-a691-f5d09513ec11   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            10m

$ kubectl get po | grep my-cluster-kafka
my-cluster-kafka-0                            1/1     Running   6 (4m26s ago)   10m
my-cluster-kafka-1                            1/1     Running   3 (71s ago)     10m
my-cluster-kafka-2                            1/1     Running   6 (4m5s ago)    10m
```

<br>

---
### Example: offline Kafka volume recovery using snapshot support

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.storage.size = \"100Mi\"" \
  | kubectl create -f - \
  && kubectl create -f sessions/001/resources/001-my-topic.yaml
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ CLUSTER_NAME="my-cluster" \
  SNAPSHOT_CLASS="ocs-external-storagecluster-rbdplugin-snapclass" \
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=$CLUSTER_NAME-kafka --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep $CLUSTER_NAME-kafka-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="20Gi"; kubectl get pv | grep $CLUSTER_NAME-kafka
pvc-2d208791-618e-4f9d-9e3d-b9f7e65f3335   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            92s
pvc-8f6a188c-ab52-49ce-a75d-c0edeaaec0d8   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            92s
pvc-9bdb58be-27d3-4be6-b0e8-8531d6958de2   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            92s
```

When the cluster is ready, we break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=$CLUSTER_NAME-kafka-bootstrap:9092
11105 records sent, 2215.7 records/sec (2.11 MB/sec), 2392.0 ms avg latency, 4559.0 ms max latency.
17616 records sent, 3521.1 records/sec (3.36 MB/sec), 6932.4 ms avg latency, 9436.0 ms max latency.
19152 records sent, 3830.4 records/sec (3.65 MB/sec), 9480.6 ms avg latency, 11175.0 ms max latency.
...
[2024-03-04 08:32:01,619] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.135.0.31:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-04 08:32:01,639] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.134.0.26:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-04 08:32:01,723] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.132.2.22:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po | grep $CLUSTER_NAME-kafka
my-cluster-kafka-0                            0/1     CrashLoopBackOff   2 (25s ago)   3m10s
my-cluster-kafka-1                            0/1     CrashLoopBackOff   2 (24s ago)   3m10s
my-cluster-kafka-2                            0/1     CrashLoopBackOff   2 (16s ago)   3m10s

$ kubectl logs $CLUSTER_NAME-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get k $CLUSTER_NAME -o yaml | yq .spec.kafka.storage.deleteClaim) == "false" ]]; then kubectl delete k $CLUSTER_NAME; fi
kafka.kafka.strimzi.io "my-cluster" deleted
```

If volume snapshot is supported, we can take Kafka volume backups and restore them on bigger volumes.
Note that snapshot operations may take some time to complete, depending on the size of the volume and the available resources in the cluster.

```sh
$ for pod in $KAFKA_PODS; do
echo -e "apiVersion: snapshot.storage.k8s.io/v1                                                 
kind: VolumeSnapshot
metadata:
  name: data-$pod-snapshot
spec:
  volumeSnapshotClassName: $SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: data-$pod" | kubectl create -f -
done
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-0-snapshot created
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-1-snapshot created
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-2-snapshot created

$ kubectl get vs | grep $CLUSTER_NAME-kafka
data-my-cluster-kafka-0-snapshot   true         data-my-cluster-kafka-0                           100Mi         ocs-external-storagecluster-rbdplugin-snapclass   snapcontent-87790258-665a-4106-896c-9211c0b482c1   13s            14s
data-my-cluster-kafka-1-snapshot   true         data-my-cluster-kafka-1                           100Mi         ocs-external-storagecluster-rbdplugin-snapclass   snapcontent-59c49c1a-2d65-4d7d-b9a0-9120dbf60c8f   12s            13s
data-my-cluster-kafka-2-snapshot   true         data-my-cluster-kafka-2                           100Mi         ocs-external-storagecluster-rbdplugin-snapclass   snapcontent-dba158cc-5e88-43fe-b580-e30282b1d8f5   11s            12s
```

Once they are ready, we can delete the old PVCs, and recreate them with bigger size from the snapshots.
We have to use the same resource name that the operator expects, so that the new volumes will be bound on cluster startup.
Note that restore operations may take some time to complete, depending on the size of the volume and the available resources in the cluster.

```sh
$ for pod in $KAFKA_PODS; do
kubectl delete pvc $(kubectl get pvc | grep data-$pod | awk '{print $1}')
echo -e "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-$pod
spec:
  storageClassName: $VOLUME_CLASS
  dataSource:
    name: data-$pod-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $NEW_VOLUME_SIZE" | kubectl create -f -
done
persistentvolumeclaim "data-my-cluster-kafka-0" deleted
persistentvolumeclaim/data-my-cluster-kafka-0 created
persistentvolumeclaim "data-my-cluster-kafka-1" deleted
persistentvolumeclaim/data-my-cluster-kafka-1 created
persistentvolumeclaim "data-my-cluster-kafka-2" deleted
persistentvolumeclaim/data-my-cluster-kafka-2 created

$ kubectl get pv | grep $CLUSTER_NAME-kafka
pvc-4bb20d8e-882d-448d-8a05-92f257019214   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            12s
pvc-a31b9572-5e52-4ef8-907e-d019db262c85   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            10s
pvc-e7146aa1-9947-4c78-bb4d-ca8b465b7729   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            15s
```

Deploy the Kafka cluster with our brand new volumes, wait for the cluster to be ready, and try to consume some data.
**Don't forget to adjust the storage size in Kafka custom resource.**
To speed up log recovery and partition synchronization, we can tune recovery threads and replica fetchers.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
  | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" \
  | yq ".spec.kafka.storage.size = \"20Gi\"" \
  | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created

$ kubectl get po -l strimzi.io/cluster=$CLUSTER_NAME
NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-entity-operator-7d6d6bd454-sh7rc   3/3     Running   0          96s
my-cluster-kafka-0                            1/1     Running   0          5m9s
my-cluster-kafka-1                            1/1     Running   0          5m9s
my-cluster-kafka-2                            1/1     Running   0          5m9s
my-cluster-zookeeper-0                        1/1     Running   0          6m14s
my-cluster-zookeeper-1                        1/1     Running   0          6m14s
my-cluster-zookeeper-2                        1/1     Running   0          6m14s

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
FHBQCYJJXEDISRBBOAKYFHTLDAJABMKLWHLRSBWBUSGRIBKSWWZQZHPHWQWZPVHLYBDVYNNOMLSAXDZSDGGQXVDETEXXEXTVNJTNOVJIYIDAFEPCIRHMQJMCRCGNVNIPISAPPHKTVRVF...
MYVZNMKXIYVTRGXHNLAXSIISAKQSPQIJKJMVYXFQVTXJVNPRZILRJKMIEBDWGCRKXFUSMWBLCVCDVXEBMXSLVXZSCPQVRNZTHKGFIBZBCOURYJEGKPJACEXCSQDFBCWXGNYERXKOHJAA...
RHTSTTCCIQLHFTWTCEUZJHADNDIYHMXSCUFDMIQXGISLNYVGNZKIJFDFQJVRWDLUNUTXNLCKSQOZNEYLRAGPFPUQSQWNJWUXLWWCLOHASOMJKNZRYSRXGIWWFTEUWVBIITCFUANCCTNT...
Processed a total of 3 messages
```

<br/>

---
### Example: offline Kafka volume recovery with no expansion and snapshot support

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.storage.size = \"100Mi\"" \
  | kubectl create -f - \
  && kubectl create -f sessions/001/resources/001-my-topic.yaml
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ CLUSTER_NAME="my-cluster" \
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=$CLUSTER_NAME-kafka --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep $CLUSTER_NAME-kafka-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="20Gi"; kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-kafka
NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-kafka-0   Bound    pvc-04b55551-fe7f-4662-9955-5e4baaf4df57   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s
data-my-cluster-kafka-1   Bound    pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s
data-my-cluster-kafka-2   Bound    pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s
```

When the cluster is ready, we break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=$CLUSTER_NAME-kafka-bootstrap:9092
12689 records sent, 2514.7 records/sec (2.40 MB/sec), 2329.9 ms avg latency, 4480.0 ms max latency.
14688 records sent, 2937.6 records/sec (2.80 MB/sec), 6876.8 ms avg latency, 9398.0 ms max latency.
14720 records sent, 2941.1 records/sec (2.80 MB/sec), 10612.5 ms avg latency, 12127.0 ms max latency.
...
[2024-02-28 10:59:21,306] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.135.0.71:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-02-28 10:59:21,309] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.134.0.38:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-02-28 10:59:21,330] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.132.2.42:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
...

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-kafka
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   1 (11s ago)   2m13s
my-cluster-kafka-1   0/1     CrashLoopBackOff   1 (13s ago)   2m13s
my-cluster-kafka-2   0/1     CrashLoopBackOff   1 (11s ago)   2m13s

$ kubectl logs $CLUSTER_NAME-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get k $CLUSTER_NAME -o yaml | yq .spec.kafka.storage.deleteClaim) == "false" ]]; then kubectl delete k $CLUSTER_NAME; fi
kafka.kafka.strimzi.io "my-cluster" deleted
```

Create new and bigger volumes for our brokers.
In this case, volumes are created automatically, but you may need to create them manually.

```sh
$ for pod in $KAFKA_PODS; do
  cat sessions/006/resources/pvc-new.yaml \
    | yq ".metadata.name = \"data-$pod-new\" \
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-kafka\" \
      | .spec.storageClassName = \"$VOLUME_CLASS\" \
      | .spec.resources.requests.storage = \"$NEW_VOLUME_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim/data-my-cluster-kafka-0-new created
persistentvolumeclaim/data-my-cluster-kafka-1-new created
persistentvolumeclaim/data-my-cluster-kafka-2-new created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-kafka
NAME                          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-kafka-0       Bound    pvc-04b55551-fe7f-4662-9955-5e4baaf4df57   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   6m11s
data-my-cluster-kafka-0-new   Bound    pvc-1a66039a-14e7-4416-9319-6d6437543c02   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   9s
data-my-cluster-kafka-1       Bound    pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   6m11s
data-my-cluster-kafka-1-new   Bound    pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   8s
data-my-cluster-kafka-2       Bound    pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   6m11s
data-my-cluster-kafka-2-new   Bound    pvc-ca348d35-f466-446e-9f93-e3c15722d214   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   7s
```

**Set the persistent volume reclaim policy to Retain, in order to avoid losing broker data when deleting Kafka PVCs.**

```sh
$ for pv in $(kubectl get pv | grep $CLUSTER_NAME-kafka | awk '{print $1}'); do
  kubectl patch pv $pv --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Retain'
done
persistentvolume/pvc-36fb911c-ded7-4c2a-ba58-1af76b2d4c53 patched
persistentvolume/pvc-4f4612c3-f81b-4d53-b14d-93e0dc9470d3 patched
persistentvolume/pvc-6ab420ec-f31c-4903-9e51-7d800c0291b2 patched
persistentvolume/pvc-81172edf-0c14-4434-9e70-880ebadc71a9 patched
persistentvolume/pvc-961db1cb-529c-442f-8106-bc9aaf5adf38 patched
persistentvolume/pvc-aea941e3-f13d-4676-ae50-6865e97aee8e patched

$ kubectl get pv | grep $CLUSTER_NAME-kafka
pvc-04b55551-fe7f-4662-9955-5e4baaf4df57   100Mi      RWO            Retain           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            6m48s
pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b   20Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-1-new                                     ocs-external-storagecluster-ceph-rbd            45s
pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9   100Mi      RWO            Retain           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            6m48s
pvc-1a66039a-14e7-4416-9319-6d6437543c02   20Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-0-new                                     ocs-external-storagecluster-ceph-rbd            45s
pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85   100Mi      RWO            Retain           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            6m48s
pvc-ca348d35-f466-446e-9f93-e3c15722d214   20Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-2-new                                     ocs-external-storagecluster-ceph-rbd            44s
```

Copy all broker data from the old volumes to the new volumes spinning up a maintenance pod.
Note that the following commands may take some time, depending on the amount of data they have to copy.

```sh
$ for pod in $KAFKA_PODS; do
  kubectl run kubectl-patch-$pod -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch-copy.yaml \
    | yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-$pod\", .spec.volumes[1].persistentVolumeClaim.claimName = \"data-$pod-new\"" \
    | yq -p yaml -o json)"
done
'/old/kafka-log0/__consumer_offsets-6/leader-epoch-checkpoint' -> '/new/kafka-log0/__consumer_offsets-6/leader-epoch-checkpoint'
'/old/kafka-log0/__consumer_offsets-6/00000000000000000000.log' -> '/new/kafka-log0/__consumer_offsets-6/00000000000000000000.log'
'/old/kafka-log0/__consumer_offsets-6/partition.metadata' -> '/new/kafka-log0/__consumer_offsets-6/partition.metadata'
'/old/kafka-log0/__consumer_offsets-6/00000000000000000000.index' -> '/new/kafka-log0/__consumer_offsets-6/00000000000000000000.index'
'/old/kafka-log0/__consumer_offsets-6/00000000000000000000.timeindex' -> '/new/kafka-log0/__consumer_offsets-6/00000000000000000000.timeindex'
'/old/kafka-log0/__consumer_offsets-6' -> '/new/kafka-log0/__consumer_offsets-6'
...
```

Now, delete all Kafka PVCs and PV claim references, just before creating the final PVCs with the new storage size.
We have to use the same resource name that the operator expects, so that the new volumes will be bound on cluster startup.

```sh
$ for pod in $KAFKA_PODS; do
  PVC_NAMES="$(kubectl get pvc | grep data-$pod | awk '{print $1}')"
  kubectl delete pvc $PVC_NAMES
  PV_NAMES="$(kubectl get pv | grep data-$pod | awk '{print $1}')"
  NEW_PV_NAME="$(kubectl get pv | grep data-$pod-new | awk '{print $1}')"
  kubectl patch pv $PV_NAMES --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  cat sessions/006/resources/pvc.yaml \
    | yq ".metadata.name = \"data-$pod\" \
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-kafka\" \
      | .spec.storageClassName = \"$VOLUME_CLASS\" \
      | .spec.volumeName = \"$NEW_PV_NAME\" \
      | .spec.resources.requests.storage = \"$NEW_VOLUME_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim "data-my-cluster-kafka-0" deleted
persistentvolumeclaim "data-my-cluster-kafka-0-new" deleted
persistentvolume/pvc-04b55551-fe7f-4662-9955-5e4baaf4df57 patched
persistentvolume/pvc-1a66039a-14e7-4416-9319-6d6437543c02 patched
persistentvolumeclaim/data-my-cluster-kafka-0 created
persistentvolumeclaim "data-my-cluster-kafka-1" deleted
persistentvolumeclaim "data-my-cluster-kafka-1-new" deleted
persistentvolume/pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b patched
persistentvolume/pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9 patched
persistentvolumeclaim/data-my-cluster-kafka-1 created
persistentvolumeclaim "data-my-cluster-kafka-2" deleted
persistentvolumeclaim "data-my-cluster-kafka-2-new" deleted
persistentvolume/pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85 patched
persistentvolume/pvc-ca348d35-f466-446e-9f93-e3c15722d214 patched
persistentvolumeclaim/data-my-cluster-kafka-2 created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-kafka
NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-kafka-0   Bound    pvc-1a66039a-14e7-4416-9319-6d6437543c02   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   15s
data-my-cluster-kafka-1   Bound    pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   10s
data-my-cluster-kafka-2   Bound    pvc-ca348d35-f466-446e-9f93-e3c15722d214   20Gi       RWO            ocs-external-storagecluster-ceph-rbd   5s
```

Deploy the Kafka cluster with our brand new volumes, wait for the cluster to be ready, and try to consume some data.
**Don't forget to adjust the storage size in Kafka custom resource.**
To speed up log recovery and partition synchronization, we can tune recovery threads and replica fetchers.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
  | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" \
  | yq ".spec.kafka.storage.size = \"20Gi\"" \
  | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created

$ kubectl get po -l strimzi.io/cluster=$CLUSTER_NAME
NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-entity-operator-7d6d6bd454-sh7rc   3/3     Running   0          96s
my-cluster-kafka-0                            1/1     Running   0          5m9s
my-cluster-kafka-1                            1/1     Running   0          5m9s
my-cluster-kafka-2                            1/1     Running   0          5m9s
my-cluster-zookeeper-0                        1/1     Running   0          6m14s
my-cluster-zookeeper-1                        1/1     Running   0          6m14s
my-cluster-zookeeper-2                        1/1     Running   0          6m14s

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
XVFTWDJKAIYRBIKZRFOEZNWURGQHGPDMOZYAEBTFLNCXMVOJOCPCXZLUZJKPTIFQVRHWKHBMTMHFHJGAIXNWURPJOKMXRAWLHMUNNWVYSNPIMZXJDKSLVMLJYZFJCQOIQXNFLYYYTEFK...
FVABXPFDUNYNYMNVYWZDVZLGZASDYATOWNFMRODUPWCUVVIZFRLZNDOSQWZVNGMGEYHDVAWZDQLXBAIZGFDUOKGGHDBTLOJLMLPXTPXXZZQXFIVTAZOHHGWJBUSMPKIPCMOAJVSLUYGJ...
OAPJJFCTIWBLZMWUVMWRSGJQMXVLATYRECKCHDEIHYOMLCLKAULDWNSRIXKVWSNHLJUADUZNUMCJQYASBCSJWHIKXLATGMGNENPSSVIUAWSRRABUBXFZZRKOGOFGTBVIWTWFUWHEEMGF...
Processed a total of 3 messages
```

Finally, we delete the old volumes to reclaim some space, and optionally set the retain policy back to Delete on new volumes.

```sh
$ kubectl delete pv $(kubectl get pv | grep Available | awk '{print $1}')
persistentvolume "pvc-04b55551-fe7f-4662-9955-5e4baaf4df57" deleted
persistentvolume "pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9" deleted
persistentvolume "pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85" deleted

$ kubectl patch pv $(kubectl get pv | grep "$CLUSTER_NAME-kafka" | awk '{print $1}') --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Delete'
persistentvolume/pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b patched
persistentvolume/pvc-1a66039a-14e7-4416-9319-6d6437543c02 patched
persistentvolume/pvc-ca348d35-f466-446e-9f93-e3c15722d214 patched

$ kubectl get pv | grep $CLUSTER_NAME-kafka
pvc-0bd38196-2f5b-4a05-8917-b43bd2dde50b   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            18m
pvc-1a66039a-14e7-4416-9319-6d6437543c02   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            18m
pvc-ca348d35-f466-446e-9f93-e3c15722d214   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            18m
```

<br>

---
### Example: offline Kafka volume recovery without additional storage

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster with 1 MiB as maximum segment size, and reducing the volume size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.config.\"log.segment.bytes\" = 1048576" \
  | yq ".spec.kafka.storage.size = \"100Mi\"" \
  | kubectl create -f - \
  && kubectl create -f sessions/001/resources/001-my-topic.yaml
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-09647b6c-bb7c-4672-a611-7fdfd8967cd1   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         ocs-external-storagecluster-ceph-rbd            3m17s
pvc-4a8fc7fb-43cb-4107-952e-8a11f09fa23d   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         ocs-external-storagecluster-ceph-rbd            3m17s
pvc-c049b7c3-8393-4fcc-9bf3-1e8a7f7f6d27   100Mi      RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         ocs-external-storagecluster-ceph-rbd            3m17s
```

When the cluster is ready, we break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
11265 records sent, 2252.5 records/sec (2.15 MB/sec), 2570.3 ms avg latency, 4608.0 ms max latency.
16784 records sent, 3356.8 records/sec (3.20 MB/sec), 7087.5 ms avg latency, 9501.0 ms max latency.
17424 records sent, 3484.8 records/sec (3.32 MB/sec), 9830.6 ms avg latency, 11900.0 ms max latency.
...
[2024-03-14 13:28:29,701] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.135.0.14:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-14 13:28:30,229] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.134.0.11:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-03-14 13:28:30,574] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.132.2.29:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
...

$ kubectl get po -l strimzi.io/name=my-cluster-kafka
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   2 (17s ago)   9m10s
my-cluster-kafka-1   0/1     CrashLoopBackOff   2 (13s ago)   9m10s
my-cluster-kafka-2   0/1     CrashLoopBackOff   2 (13s ago)   9m10s

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get k my-cluster -o yaml | yq .spec.kafka.storage.deleteClaim) == "false" ]]; then kubectl delete k my-cluster; fi
kafka.kafka.strimzi.io "my-cluster" deleted
```

In cases where additional storage is not available, another option is to delete the old segments to free up some space.
**Pay attention on which segments you delete to avoid losing unconsumed or important data.
Here we only delete the oldest 10 segments of my-topic partitions on broker-0, but you have to repeat the same procedure on each failing broker pod.**

```sh
$ POD="my-cluster-kafka-0"; \
  kubectl run kubectl-patch-$POD --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch-delete.yaml \
    | yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-$POD\"" \
    | yq -p yaml -o json)"
pod/kubectl-patch-my-cluster-kafka-0 created
    
$ kubectl -itq exec kubectl-patch-$POD -- sh
```
```
/ # df -h /data
Filesystem                Size      Used Available Use% Mounted on
/dev/rbd2                88.2M     86.2M         0 100% /data

/ # LOG_DIR="/data/kafka-log0" TOPIC="my-topic" NUM_SEGMENTS="10"; \
  for partition in $(ls $LOG_DIR | grep $TOPIC); do
    OLDEST_SEGMENTS=$(ls $LOG_DIR/$partition | grep -E '\.log' | sort -z | head -$NUM_SEGMENTS | awk -F'.' '{print $1}')
    for segment in $OLDEST_SEGMENTS; do find $LOG_DIR/$partition -name "$segment.*" -exec rm -rfv {} \;; done
  done
removed '/data/kafka-log0/my-topic-0/00000000000000000000.log'
removed '/data/kafka-log0/my-topic-0/00000000000000000000.timeindex'
removed '/data/kafka-log0/my-topic-0/00000000000000000000.index'
removed '/data/kafka-log0/my-topic-0/00000000000000001024.snapshot'
removed '/data/kafka-log0/my-topic-0/00000000000000001024.log'
removed '/data/kafka-log0/my-topic-0/00000000000000001024.index'
...
removed '/data/kafka-log0/my-topic-1/00000000000000000000.log'
removed '/data/kafka-log0/my-topic-1/00000000000000000000.timeindex'
removed '/data/kafka-log0/my-topic-1/00000000000000000000.index'
removed '/data/kafka-log0/my-topic-1/00000000000000001024.log'
removed '/data/kafka-log0/my-topic-1/00000000000000001024.index'
removed '/data/kafka-log0/my-topic-1/00000000000000001024.timeindex'
...
removed '/data/kafka-log0/my-topic-2/00000000000000000000.log'
removed '/data/kafka-log0/my-topic-2/00000000000000000000.timeindex'
removed '/data/kafka-log0/my-topic-2/00000000000000000000.index'
removed '/data/kafka-log0/my-topic-2/00000000000000001024.snapshot'
removed '/data/kafka-log0/my-topic-2/00000000000000001024.log'
removed '/data/kafka-log0/my-topic-2/00000000000000001024.index'
removed '/data/kafka-log0/my-topic-2/00000000000000001024.timeindex'
...

/ # df -h /data
Filesystem                Size      Used Available Use% Mounted on
/dev/rbd2                88.2M     56.5M     29.8M  65% /data

/ # exit
```
```sh
$ kubectl delete po kubectl-patch-$POD
pod "kubectl-patch-my-cluster-kafka-0" deleted
```

**Before restarting the cluster, we also need to adjust the retention settings to avoid running out of disk space again.**
Here we set max retention size to 50 MiB at the topic level, and add some configuration at the broker level to speed up log recovery.

```sh
$ cat sessions/001/resources/001-my-topic.yaml \
  | yq ".spec.config.\"retention.bytes\" = 52428800" \
  | kubectl apply -f -
kafkatopic.kafka.strimzi.io/my-topic configured

$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
  | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" \
  | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created
```

Once the cluster is ready, we first check if it works, and then repeat the load test again and see if the new retention settings help to avoid running out of disk.

```sh
$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
SEDINDZFKBANJUMUJISTWWHSMXCXMFYTARBZCXJGFEWLAZVCXYIMMGYGNQTMNSJMMZCERXJBWATARIVJYNSECNSUSSSLOPYWVZQCFLDMQATUANHOCEVYJWZKDJKJNRQBZQFBCATHZOCH...
KIIHTXKNKIVTPCILIYHYYMLVSOAPJGTUFBLUYENFMPIQYRZCNDZCCHJFKAOANFYTOSTQLOCVMQNENHNMJOPFYETJRMTKQCBLNTXXWQHJOHNKNIGNFCDVMVLSNXWYYQEMUQQIRXPLIAJH...
YQKQSKRBHTBCIZAIVLTPOFETQGWTYCBFKSAORUTJHSXUQKPSIRTYHXWEMFDTLHXISDUGNXHQJOPLXTATUIODQGPTOYPBEQYCXQZBSHDLYCINLSFURIGQEJWDQLSNLVUTIXTPBLOXGTZA...
Processed a total of 3 messages

$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 110000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
12641 records sent, 2524.2 records/sec (2.41 MB/sec), 2673.9 ms avg latency, 4664.0 ms max latency.
17536 records sent, 3507.2 records/sec (3.34 MB/sec), 7062.6 ms avg latency, 9557.0 ms max latency.
17344 records sent, 3464.6 records/sec (3.30 MB/sec), 9542.8 ms avg latency, 11564.0 ms max latency.
18688 records sent, 3736.9 records/sec (3.56 MB/sec), 8885.3 ms avg latency, 11739.0 ms max latency.
21168 records sent, 4230.2 records/sec (4.03 MB/sec), 8628.9 ms avg latency, 12224.0 ms max latency.
18704 records sent, 3740.1 records/sec (3.57 MB/sec), 8395.0 ms avg latency, 10452.0 ms max latency.
110000 records sent, 3426.577783 records/sec (3.27 MB/sec), 7857.89 ms avg latency, 12224.00 ms max latency, 8265 ms 50th, 11516 ms 95th, 12048 ms 99th, 12203 ms 99.9th.
```

<br/>

---
### Example: online ZooKeeper recovery from corrupted storage with quorum loss

This example has some tricky steps highlighted in bold, where you need to be extra careful.
**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001).

When the cluster is ready, we create a topic first so that it can be used to make sure the data is not lost after recovery.
And then break 2 ZooKeeper servers by writing corrupted data into ZK log.

```sh
$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --create --topic t0
Created topic t0.

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic t0
Topic: t0	TopicId: 1Sgy6V-CR0K7MMJ9khDuRw	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t0	Partition: 0	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	Topic: t0	Partition: 1	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0
	Topic: t0	Partition: 2	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2

$ kubectl exec my-cluster-zookeeper-0 -- sh -c "echo 'test' > /var/lib/zookeeper/data/version-2/log.200000001"  \
  && kubectl delete po my-cluster-zookeeper-0
pod "my-cluster-zookeeper-0" deleted

$ kubectl exec my-cluster-zookeeper-1 -- sh -c "echo 'test' > /var/lib/zookeeper/data/version-2/log.200000001"  \
  && kubectl delete po my-cluster-zookeeper-1
pod "my-cluster-zookeeper-1" deleted

$ kubectl get po -l strimzi.io/name=my-cluster-zookeeper
NAME                     READY   STATUS             RESTARTS        AGE
my-cluster-zookeeper-0   0/1     CrashLoopBackOff   5 (2m16s ago)   16m
my-cluster-zookeeper-1   0/1     CrashLoopBackOff   4 (2m16s ago)   16m
my-cluster-zookeeper-2   1/1     Running            0               16m

$ kubectl logs my-cluster-zookeeper-0 | grep "Unable to load database on disk" | tail -n1
2024-03-01 08:53:40,806 ERROR Unable to load database on disk (org.apache.zookeeper.server.quorum.QuorumPeer) [main]
```

We need to remove all data from the failed Zookeeper volumes to allow it get re-synced with the leader.
Double check that the volume access mode is ReadWriteOnly (RWO), so that we can start up a pod within the same node to update the data in the volume.

```sh
$ kubectl get pvc -l strimzi.io/name=my-cluster-zookeeper
NAME                          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-zookeeper-0   Bound    pvc-8e8d3aac-2e38-4f1c-b11e-dd66003cbcae   5Gi        RWO            ocs-external-storagecluster-ceph-rbd   13m
data-my-cluster-zookeeper-1   Bound    pvc-f79b9a18-515d-4992-b92f-186a93ca05ff   5Gi        RWO            ocs-external-storagecluster-ceph-rbd   13m
data-my-cluster-zookeeper-2   Bound    pvc-2b390fa8-f791-478d-9136-d4e44b4a8e80   5Gi        RWO            ocs-external-storagecluster-ceph-rbd   13m

$ NODE_HOSTNAME_0="$(kubectl describe pod my-cluster-zookeeper-0 | grep Node: | awk '{print $2}' | cut -d / -f1)"
$ NODE_HOSTNAME_1="$(kubectl describe pod my-cluster-zookeeper-1 | grep Node: | awk '{print $2}' | cut -d / -f1)"

$ kubectl run kubectl-remove-zookeeper-0 -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch-zk.yaml \
| yq ".spec.nodeSelector.\"kubernetes.io/hostname\" = \"$NODE_HOSTNAME_0\"" \
| yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-my-cluster-zookeeper-0\"" \
| yq -p yaml -o json)"
removed '/zookeeper/data/version-2/acceptedEpoch'
removed '/zookeeper/data/version-2/currentEpoch'
removed '/zookeeper/data/version-2/log.200000001'
removed '/zookeeper/data/version-2/snapshot.0'

$ kubectl run kubectl-remove-zookeeper-1 -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch-zk.yaml \
| yq ".spec.nodeSelector.\"kubernetes.io/hostname\" = \"$NODE_HOSTNAME_1\"" \
| yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-my-cluster-zookeeper-1\"" \
| yq -p yaml -o json)"
removed '/zookeeper/data/version-2/acceptedEpoch'
removed '/zookeeper/data/version-2/currentEpoch'
removed '/zookeeper/data/version-2/log.200000001'
removed '/zookeeper/data/version-2/snapshot.0'
```

Restart all failed pods so that they can sync up with the leader.
Trying to describe the topic created at first step to make sure data is not lost.

```sh
$ kubectl delete po my-cluster-zookeeper-0 --force && kubectl delete po my-cluster-zookeeper-1 --force
pod "my-cluster-zookeeper-0" deleted
pod "my-cluster-zookeeper-1" deleted

$ kubectl get po -l strimzi.io/cluster=my-cluster
NAME                                          READY   STATUS    RESTARTS   AGE
my-cluster-entity-operator-7d6d6bd454-sh7rc   3/3     Running   0          96s
my-cluster-kafka-0                            1/1     Running   0          5m9s
my-cluster-kafka-1                            1/1     Running   0          5m9s
my-cluster-kafka-2                            1/1     Running   0          5m9s
my-cluster-zookeeper-0                        1/1     Running   0          6m14s
my-cluster-zookeeper-1                        1/1     Running   0          6m14s
my-cluster-zookeeper-2                        1/1     Running   0          6m14s

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic t0
Topic: t0	TopicId: 1Sgy6V-CR0K7MMJ9khDuRw	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t0	Partition: 0	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	Topic: t0	Partition: 1	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0
	Topic: t0	Partition: 2	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
```

If there is only 1 server with storage issue, please go through the same process for the specific node.
