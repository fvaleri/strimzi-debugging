## Storage requirements and recovery

Kafka and ZooKeeper require low-latency storage.
The recommended storage type is block storage (e.g. SSD, NVMe, AWS EBS), as it offers superior efficiency and faster performance compared to file and object storage types.
However, Kafka doesn't directly utilize raw block devices; instead, it writes data to segment files stored on a standard file system.
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

This example has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
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

This example has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
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

This example has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
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
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=my-cluster-kafka --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep my-cluster-kafka-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="20Gi"

$ kubectl get pv | grep $CLUSTER_NAME-kafka
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
^CProcessed a total of 3 messages
```

<br/>

---
### Example: offline Kafka volume recovery with no expansion and snapshot support

This example has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
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
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=my-cluster-kafka --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep my-cluster-kafka-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="20Gi"
  
$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-kafka
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
  kubectl run kubectl-copy-$pod -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch.yaml \
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
^CProcessed a total of 3 messages
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
<br/>
---
### Example: ZooKeeper storage failure with lost quorum (offline recovery)

This procedure has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
**Don't use Minikube for this example, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the disk size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
    | yq ".spec.zookeeper.storage.size = \"1Mi\"" \
    | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created

$ kubectl create -f sessions/001/resources/001-my-topic.yaml
kafkatopic.kafka.strimzi.io/my-topic created
```

When the cluster is ready, break zookeeper by creating 3 topics with 1000 partitions each, which exceeds the disk capacity of 1 MiB.

```sh
$ CLUSTER_NAME="my-cluster" \
  ZK_PODS="$(kubectl get po -l strimzi.io/name=my-cluster-zookeeper --no-headers -o custom-columns=':metadata.name')" \
  NEW_PV_CLASS="$(kubectl get pv | grep my-cluster-zookeeper-0 | awk '{print $7}')" \
  NEW_PV_SIZE="100Mi"

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-zookeeper
NAME                          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-zookeeper-0   Bound    pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   6m45s
data-my-cluster-zookeeper-1   Bound    pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   6m45s
data-my-cluster-zookeeper-2   Bound    pvc-90f07fde-7482-4764-b013-a04aac4e41fb   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   6m45s


$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --create --topic t0 --partitions 1000 \
  && kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --create --topic t1 --partitions 1000 \
  && kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --create --topic t2 --partitions 1000
Created topic t0.
Created topic t1.
Error while executing topic command : The request timed out.
[2024-02-29 09:42:21,758] ERROR org.apache.kafka.common.errors.TimeoutException: The request timed out.
 (kafka.admin.TopicCommand$)

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-zookeeper
NAME                     READY   STATUS             RESTARTS        AGE
my-cluster-zookeeper-0   0/1     CrashLoopBackOff   5 (2m16s ago)   16m
my-cluster-zookeeper-1   0/1     CrashLoopBackOff   5 (2m24s ago)   16m
my-cluster-zookeeper-2   1/1     Running            0               16m

$ kubectl logs $CLUSTER_NAME-zoookeeper-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all servers because the storage configuration is shared.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get k $CLUSTER_NAME -o yaml | yq .spec.zookeeper.storage.deleteClaim) == "false" ]]; then kubectl delete k $CLUSTER_NAME; fi
kafka.kafka.strimzi.io "my-cluster" deleted
```

Create new and bigger volumes for our servers.
In this case, volumes are created automatically, but you may need to create them manually.

```sh
$ for pod in $ZK_PODS; do
  cat sessions/006/resources/pvc-new.yaml \
    | yq ".metadata.name = \"data-$pod-new\" \
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-zookeeper\" \
      | .spec.storageClassName = \"$NEW_PV_CLASS\" \
      | .spec.resources.requests.storage = \"$NEW_PV_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim/data-my-cluster-zookeeper-0-new created
persistentvolumeclaim/data-my-cluster-zookeeper-1-new created
persistentvolumeclaim/data-my-cluster-zookeeper-2-new created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-zookeeper
NAME                              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-zookeeper-0       Bound    pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   10m
data-my-cluster-zookeeper-0-new   Bound    pvc-e56566de-8b03-4505-8872-f12603dea51f   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   12s
data-my-cluster-zookeeper-1       Bound    pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   10m
data-my-cluster-zookeeper-1-new   Bound    pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   11s
data-my-cluster-zookeeper-2       Bound    pvc-90f07fde-7482-4764-b013-a04aac4e41fb   1Mi        RWO            ocs-external-storagecluster-ceph-rbd   10m
data-my-cluster-zookeeper-2-new   Bound    pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   9s
```

**Set the persistent volume reclaim policy to Retain, in order to avoid losing broker data when deleting Zookeeper PVCs.**

```sh
$ for pv in $(kubectl get pv | grep $CLUSTER_NAME-zookeeper | awk '{print $1}'); do
  kubectl patch pv $pv --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Retain'
done
persistentvolume/pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf patched
persistentvolume/pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc patched
persistentvolume/pvc-90f07fde-7482-4764-b013-a04aac4e41fb patched
persistentvolume/pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1 patched
persistentvolume/pvc-e56566de-8b03-4505-8872-f12603dea51f patched
persistentvolume/pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec patched

$ kubectl get pv | grep $CLUSTER_NAME-zookeeper
pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf   100Mi      RWO            Retain           Bound    test/data-my-cluster-zookeeper-2-new                                 ocs-external-storagecluster-ceph-rbd            47s
pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc   1Mi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-0                                     ocs-external-storagecluster-ceph-rbd            11m
pvc-90f07fde-7482-4764-b013-a04aac4e41fb   1Mi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-2                                     ocs-external-storagecluster-ceph-rbd            11m
pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1   100Mi      RWO            Retain           Bound    test/data-my-cluster-zookeeper-1-new                                 ocs-external-storagecluster-ceph-rbd            49s
pvc-e56566de-8b03-4505-8872-f12603dea51f   100Mi      RWO            Retain           Bound    test/data-my-cluster-zookeeper-0-new                                 ocs-external-storagecluster-ceph-rbd            50s
pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec   1Mi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-1                                     ocs-external-storagecluster-ceph-rbd            11m
```

Copy all servers data from the old volumes to the new volumes spinning up a maintenance pod.
Note that the following commands may take some time, depending on the amount of data they have to copy.

```sh
$ for pod in $ZK_PODS; do
  kubectl run kubectl-copy-$pod -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch.yaml \
    | yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-$pod\", .spec.volumes[1].persistentVolumeClaim.claimName = \"data-$pod-new\"" \
    | yq -p yaml -o json)"
done
'/old/data/myid' -> '/new/data/myid'
'/old/data/version-2/currentEpoch' -> '/new/data/version-2/currentEpoch'
'/old/data/version-2/log.200000001' -> '/new/data/version-2/log.200000001'
'/old/data/version-2/acceptedEpoch' -> '/new/data/version-2/acceptedEpoch'
'/old/data/version-2/snapshot.0' -> '/new/data/version-2/snapshot.0'
'/old/data/version-2' -> '/new/data/version-2'
'/old/data' -> '/new/data'
'/old/logs' -> '/new/logs'
'/old/lost+found' -> '/new/lost+found'
...
```

After that, we need to create the conditions for them to be reattached by the Kafka cluster.
Delete the all Zookeeper PVCs and PV claim references, just before creating the final PVCs with the new storage size.

```sh
$ for pod in $ZK_PODS; do
  PVC_NAMES="$(kubectl get pvc | grep data-$pod | awk '{print $1}')"
  kubectl delete pvc $PVC_NAMES
  PV_NAMES="$(kubectl get pv | grep data-$pod | awk '{print $1}')"
  NEW_PV_NAME="$(kubectl get pv | grep data-$pod-new | awk '{print $1}')"
  kubectl patch pv $PV_NAMES --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  cat sessions/006/resources/pvc.yaml \
    | yq ".metadata.name = \"data-$pod\" \
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-zookeeper\" \
      | .spec.storageClassName = \"$NEW_PV_CLASS\" \
      | .spec.volumeName = \"$NEW_PV_NAME\" \
      | .spec.resources.requests.storage = \"$NEW_PV_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim "data-my-cluster-zookeeper-0" deleted
persistentvolumeclaim "data-my-cluster-zookeeper-0-new" deleted
persistentvolume/pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc patched
persistentvolume/pvc-e56566de-8b03-4505-8872-f12603dea51f patched
persistentvolumeclaim/data-my-cluster-zookeeper-0 created
persistentvolumeclaim "data-my-cluster-zookeeper-1" deleted
persistentvolumeclaim "data-my-cluster-zookeeper-1-new" deleted
persistentvolume/pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1 patched
persistentvolume/pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec patched
persistentvolumeclaim/data-my-cluster-zookeeper-1 created
persistentvolumeclaim "data-my-cluster-zookeeper-2" deleted
persistentvolumeclaim "data-my-cluster-zookeeper-2-new" deleted
persistentvolume/pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf patched
persistentvolume/pvc-90f07fde-7482-4764-b013-a04aac4e41fb patched
persistentvolumeclaim/data-my-cluster-zookeeper-2 created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-zookeeper
NAME                          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-zookeeper-0   Bound    pvc-e56566de-8b03-4505-8872-f12603dea51f   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   34s
data-my-cluster-zookeeper-1   Bound    pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   26s
data-my-cluster-zookeeper-2   Bound    pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   14s
```

Deploy the Kafka cluster with our brand new volumes, and then try to consume some data.
**Don't forget to adjust the Zookeeper storage size in Kafka custom resource.**

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
  | yq ".spec.zookeeper.storage.size = \"100Mi\"" \
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

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --topic t0 --describe
Topic: t0	TopicId: O_jLcdCZQuyNgxSGNOZDHg	PartitionCount: 1000	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t0	Partition: 0	Leader: 1	Replicas: 1,2,0	Isr: 1,0,2
	Topic: t0	Partition: 1	Leader: 1	Replicas: 0,1,2	Isr: 1,0,2
	Topic: t0	Partition: 2	Leader: 1	Replicas: 2,0,1	Isr: 1,0,2
	Topic: t0	Partition: 3	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
	...
	Topic: t0	Partition: 999	Leader: 1	Replicas: 0,1,2	Isr: 1,0,2

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --topic t1 --describe
Topic: t1	TopicId: Zz3T1a_hQiGvHv8LLK7H9Q	PartitionCount: 1000	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t1	Partition: 0	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
	Topic: t1	Partition: 1	Leader: 1	Replicas: 0,2,1	Isr: 1,0,2
	Topic: t1	Partition: 2	Leader: 1	Replicas: 2,1,0	Isr: 1,0,2
	Topic: t1	Partition: 3	Leader: 1	Replicas: 1,2,0	Isr: 1,0,2
	...
	Topic: t1	Partition: 999	Leader: 1	Replicas: 0,1,2	Isr: 1,0,2
```
We can also get the topic t2's information even though it caused disk full when creating topic t2.
If this command didn't show expected results, try to run the command later since zookeeper also needs time to do data recovery, 
and Kafka needs time to complete the topic t2 creation because it failed to create before Zookeeper server disk full. 

```
$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --describe --topic t2
Topic: t2	TopicId: LCYz44eWSYmMA1xhY9BpdQ	PartitionCount: 1000	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t2	Partition: 0	Leader: 0	Replicas: 1,0,2	Isr: 0,1,2
	Topic: t2	Partition: 1	Leader: 0	Replicas: 0,2,1	Isr: 0,1,2
	Topic: t2	Partition: 2	Leader: 0	Replicas: 2,1,0	Isr: 0,1,2
	Topic: t2	Partition: 3	Leader: 0	Replicas: 1,2,0	Isr: 0,1,2
	...
	Topic: t2	Partition: 999	Leader: 0	Replicas: 1,2,0	Isr: 0,1,2
```

Finally, we delete the old volumes to reclaim some space, and optionally set the retain policy back to Delete on new volumes.

```sh
$ kubectl delete pv $(kubectl get pv | grep Available | awk '{print $1}')
persistentvolume "pvc-8f3ddfba-e73a-4469-92e1-c8abc62006cc" deleted
persistentvolume "pvc-90f07fde-7482-4764-b013-a04aac4e41fb" deleted
persistentvolume "pvc-f6b43572-30ff-4423-a2eb-50d6733c55ec" deleted

$ kubectl patch pv $(kubectl get pv | grep "$CLUSTER_NAME-zookeeper" | awk '{print $1}') --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Delete'
persistentvolume/pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf patched
persistentvolume/pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1 patched
persistentvolume/pvc-e56566de-8b03-4505-8872-f12603dea51f patched

$ kubectl get pv | grep $CLUSTER_NAME-zookeeper
pvc-62dc40e2-8732-4563-bd9c-97a480f35dbf   100Mi      RWO            Delete           Bound    test/data-my-cluster-zookeeper-2                                     ocs-external-storagecluster-ceph-rbd            6m28s
pvc-d33f37a9-de7e-4b6a-8ab1-e0522571ebb1   100Mi      RWO            Delete           Bound    test/data-my-cluster-zookeeper-1                                     ocs-external-storagecluster-ceph-rbd            6m30s
pvc-e56566de-8b03-4505-8872-f12603dea51f   100Mi      RWO            Delete           Bound    test/data-my-cluster-zookeeper-0                                     ocs-external-storagecluster-ceph-rbd            6m31s
```
