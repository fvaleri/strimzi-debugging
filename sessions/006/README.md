## Storage requirements and volume recovery

Kafka requires low latency storage for both broker commit logs and ZooKeeper data.
The block storage type offers greater efficiency and faster performance than file and object storage types, which is why it is often recommended for Kafka.
That said, Kafka does NOT directly use raw block devices, but instead writes to segment files that are stored on a standard file system.
These segment files are memory mapped for improved performance, which enables zero-copy optimization when TLS is not configured.
There is no hard dependency on a specific file system, although XFS is recommended.
NFS is known to cause problems when renaming files.

When the producer and consumer are fast enough, disk usage is not necessary, but it is required when old data needs to be read or when the operating system needs to flush dirty pages. 
In these scenarios, disk speed and latency are important factors, including tail latencies (such as p95 and p99) if there are end-to-end message latency requirements.
The specific characteristics of the storage system depend on the particular use case. 
It may be helpful to compare against local storage options such as SSD or NVMe, or to consider a shared storage environment such as NVMe-oF or NVMe/TCP.

Both Kafka and Zookeeper have built-in data replication, so they do not need replicated storage to ensure data availability, which would only add network overhead.
You can also use JBOD (just a bunch of disks), which gives good performance when using multiple disks in parallel.
An easy optimization to improve performance is to disable the last access time file attribute (`noatime`).
By disabling `noatime`, the system can avoid unnecessary disk I/O operations and reduce the overall overhead of file system access.

Ideally, when provisioning a new Kafka cluster or topic, the retention policy should be set properly based on requirements and expected throughput (MB/s).
Log segments become inactive after a period of time determined by `segment.ms`, or after reaching a certain size determined by `segment.bytes`.
By default and if you don't set your own, the record's time is set by the producer application with the current time of its system clock.
If only one record is not yet eligible for deletion based on `retention.ms` or `retention.bytes`, the broker retains the entire segment file.
For this reason, it is usually recommended to set both time and size based retention, and you can also set `log.message.timestamp.type=LogAppendTime`.
Deletion timing also depends on the cluster load and how many `background.threads` are available for normal topics, and `log.cleaner.threads` for compacted topics.
The required storage capacity can be  estimated based on the calculation from message write rate and the retention policy.

- Time based storage capacity (MB) = retention_sec * topic_write_rate (MB/s) * replication_factor
- Size based storage capacity (MB) = retention_mb * replication_factor

When very old segments are not deleted in your cluster, you should confirm that there are future timestamps by consuming all records or using the dump tool.
If there are some, you can fix the issue by adding the size based retention configuration, taking care of not deleting good data.
Additionally, you can also set `log.message.timestamp.type=LogAppendTime` at the broker level.

In OpenShift, a persistent volume (PV) lives outside any namespace, and it is claimed by using a persistent volume claim (PVC).
You can specify the storage class (SC) used for provisioning directly in the Kafka CR.
Only volumes created and managed by a SC with `allowVolumeExpansion: true` can be increased, but not decreased.
When using JBOD, you can also remove a volume, but data needs to be migrated to other volumes upfront.
Volumes with either `persistentVolumeReclaimPolicy: Retain`, or using a storage class with `reclaimPolicy: Retain` are retained when the Kafka cluster is deleted.

<br/>

---
### Example: no space left on device WITH volume expansion

First, [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001).
When the cluster is ready, break it by sending 11 GiB of data to a topic, which exceeds the disk capacity of 10 GiB.

```sh
$ kubectl get pv | grep kafka
pvc-2e3c7665-2b92-4376-bb1d-22b1d23fcc6a   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     4m1s
pvc-b1e5e0a3-ab83-487f-9b81-c38e1badfccc   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     4m1s
pvc-e66030cd-3992-4adc-9d94-d9d4ab164a45   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     4m1s

$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 11000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
287699 records sent, 57528.3 records/sec (54.86 MB/sec), 144.6 ms avg latency, 455.0 ms max latency.
309618 records sent, 61923.6 records/sec (59.05 MB/sec), 29.1 ms avg latency, 132.0 ms max latency.
301344 records sent, 60268.8 records/sec (57.48 MB/sec), 53.2 ms avg latency, 361.0 ms max latency.
...
[2022-10-14 15:14:26,695] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.128.2.32:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-10-14 15:14:26,885] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.129.2.59:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-10-14 15:14:27,036] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.131.0.37:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po | grep kafka
my-cluster-kafka-0                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-1                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-2                            0/1     CrashLoopBackOff   3 (20s ago)   15m

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods failed, like in this case, we still need to increase the volume size of all brokers because the storage configuration is shared.
If volume expansion is supported, you can simply edit the Kafka Custom Resource (CR) to specify the desired disk size increase, and the operator will handle the rest of the process. 
However, it's important to note that the expansion process may take some time to complete, depending on the size of the volume and the available resources in the cluster.

```sh
$ kubectl get sc $(kubectl get pv | grep data-my-cluster-kafka-0 | awk '{print $7}') -o yaml | yq '.allowVolumeExpansion'
true

$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      storage:
        size: 20Gi'
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl logs $(kubectl get po | grep cluster-operator | cut -d" " -f1) | grep "Resizing"
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-0 from 10 to 20Gi.
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-1 from 10 to 20Gi.
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-2 from 10 to 20Gi.

$ kubectl get pv | grep kafka
pvc-2e3c7665-2b92-4376-bb1d-22b1d23fcc6a   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     30m
pvc-b1e5e0a3-ab83-487f-9b81-c38e1badfccc   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     30m
pvc-e66030cd-3992-4adc-9d94-d9d4ab164a45   20Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     30m

$ kubectl get po | grep kafka
my-cluster-kafka-0                            1/1     Running   0             2m22s
my-cluster-kafka-1                            1/1     Running   0             3m37s
my-cluster-kafka-2                            1/1     Running   0             4m53s
```

<br>

---
### Example: no space left on device WITHOUT volume expansion

This procedure has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
**Don't use Minikube for this example, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the disk size.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml \
    | yq ".spec.kafka.storage.size = \"100Mi\"" \
    | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created

$ kubectl create -f sessions/001/resources/001-my-topic.yaml
kafkatopic.kafka.strimzi.io/my-topic created
```

When the cluster is ready, break it by sending 110 MiB of data to a topic, which exceeds the disk capacity of 100 MiB.

```sh
$ CLUSTER_NAME="my-cluster" \
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=my-cluster-kafka --no-headers -o custom-columns=':metadata.name')" \
  NEW_PV_CLASS="$(kubectl get pv | grep my-cluster-kafka-0 | awk '{print $7}')" \
  NEW_PV_SIZE="20Gi"
  
$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-kafka
NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                           AGE
data-my-cluster-kafka-0   Bound    pvc-04b55551-fe7f-4662-9955-5e4baaf4df57   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s
data-my-cluster-kafka-1   Bound    pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s
data-my-cluster-kafka-2   Bound    pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85   100Mi      RWO            ocs-external-storagecluster-ceph-rbd   106s

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
my-cluster-kafka-0   0/1     CrashLoopBackOff   3 (32s ago)   7m42s
my-cluster-kafka-1   0/1     CrashLoopBackOff   3 (36s ago)   7m42s
my-cluster-kafka-2   1/1     Running            2 (99s ago)   7m42s

$ kubectl logs $CLUSTER_NAME-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
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
      | .spec.storageClassName = \"$NEW_PV_CLASS\" \
      | .spec.resources.requests.storage = \"$NEW_PV_SIZE\"" \
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

After that, we need to create the conditions for them to be reattached by the Kafka cluster.
Delete the all Kafka PVCs and PV claim references, just before creating the final PVCs with the new storage size.

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
      | .spec.storageClassName = \"$NEW_PV_CLASS\" \
      | .spec.volumeName = \"$NEW_PV_NAME\" \
      | .spec.resources.requests.storage = \"$NEW_PV_SIZE\"" \
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

Deploy the Kafka cluster with our brand new volumes, and then try to consume some data.
**Don't forget to adjust the storage size in Kafka custom resource.**
To help speed up log recovery and partition synchronization, we can bump `num.recovery.threads.per.data.dir` and `num.replica.fetchers`.

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


<br/>

---
### Example: ZooKeeper storage failure with lost quorum (online recovery)

This procedure has some tricky steps highlighted in bold, where you need to be extra careful to avoid losing data.
**Don't use Minikube for this example, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).


When the cluster is ready, break 1 zookeeper node by writing corrupted data into ZK log.

```sh
$ CLUSTER_NAME="my-cluster" \
  ZK_PODS="$(kubectl get po -l strimzi.io/name=my-cluster-zookeeper --no-headers -o custom-columns=':metadata.name')" \

$ kubectl exec -it $CLUSTER_NAME-zookeeper-0 -- bash -c "echo 'test' > /var/lib/zookeeper/data/version-2/log.200000001"

$ kubectl delete po $CLUSTER_NAME-zookeeper-0
pod "my-cluster-zookeeper-0" deleted

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-zookeeper
NAME                     READY   STATUS             RESTARTS        AGE
my-cluster-zookeeper-0   0/1     CrashLoopBackOff   5 (2m16s ago)   16m
my-cluster-zookeeper-1   1/1     Running            0               16m
my-cluster-zookeeper-2   1/1     Running            0               16m

$ kubectl logs $CLUSTER_NAME-zoookeeper-0 | grep "Unable to load database on disk" | tail -n1
2024-03-01 08:53:40,806 ERROR Unable to load database on disk (org.apache.zookeeper.server.quorum.QuorumPeer) [main]
```

We need to delete the node to save the storage in the failed node.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get k $CLUSTER_NAME -o yaml | yq .spec.zookeeper.storage.deleteClaim) == "false" ]]; then kubectl delete k $CLUSTER_NAME; fi
kafka.kafka.strimzi.io "my-cluster" deleted
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

Remove all servers data from the Zookeeper volumes to allow it get re-synced with the leader.

```sh
$ for pod in $ZK_PODS; do
  kubectl run kubectl-remove-zookeeper-0 -itq --rm --restart "Never" --image "foo" --overrides "$(cat sessions/006/resources/patch_ZK_online.yaml \
    | yq ".spec.volumes[0].persistentVolumeClaim.claimName = \"data-my-cluster-zookeeper-0\"" \
    | yq -p yaml -o json)"
done
removed '/zookeeper/data/version-2/acceptedEpoch'
removed '/zookeeper/data/version-2/currentEpoch'
removed '/zookeeper/data/version-2/log.200000001'
removed '/zookeeper/data/version-2/snapshot.0'
```

Re-deploy the Kafka cluster.

```sh
$ kubectl apply -f sessions/001/resources/
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

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --topic t0 --create

$ kubectl-kafka bin/kafka-topics.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 --topic t0 --describe
Topic: t0	TopicId: 1Sgy6V-CR0K7MMJ9khDuRw	PartitionCount: 3	ReplicationFactor: 3	Configs: min.insync.replicas=2,message.format.version=3.0-IV1
	Topic: t0	Partition: 0	Leader: 0	Replicas: 0,2,1	Isr: 0,2,1
	Topic: t0	Partition: 1	Leader: 2	Replicas: 2,1,0	Isr: 2,1,0
	Topic: t0	Partition: 2	Leader: 1	Replicas: 1,0,2	Isr: 1,0,2
```

Finally, we set the retain policy back to Delete on new volumes.

```sh
$ kubectl patch pv $(kubectl get pv | grep "$CLUSTER_NAME-zookeeper" | awk '{print $1}') --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Delete'
persistentvolume/pvc-131a97de-2f08-45f6-aba4-e5cd2a75a635 patched
persistentvolume/pvc-658b8784-9e32-4a64-93c6-f94404ee7c85 patched
persistentvolume/pvc-a9073ee4-1845-479d-9d1d-42c3e07f2e3d patched

$ kubectl get pv | grep $CLUSTER_NAME-zookeeper
kubectl get pv | grep $CLUSTER_NAME-zookeeper
pvc-131a97de-2f08-45f6-aba4-e5cd2a75a635   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-2                                     ocs-external-storagecluster-ceph-rbd            38m
pvc-658b8784-9e32-4a64-93c6-f94404ee7c85   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-1                                     ocs-external-storagecluster-ceph-rbd            38m
pvc-a9073ee4-1845-479d-9d1d-42c3e07f2e3d   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-0                                     ocs-external-storagecluster-ceph-rbd            38m
```
