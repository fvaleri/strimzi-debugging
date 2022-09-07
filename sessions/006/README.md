## Storage requirements and volume recovery

Kafka requires low latency block storage to store both broker commit logs and Zookeeper database. File storage like NFS
does not work well (silly rename problem). Both Apache Kafka and Apache Zookeeper have data replication built in, so
they do not need replicated storage to ensure data availability, which would only add network overhead. z\In case local
storage is not available, Streams can also work with network attached block storage such as iSCSI or Fibre Channel, and
with most block storage services such as Amazon EBS. JBOD (just a bunch of disks) is also supported, and can actually
give good performance because you are using multiple disk in parallel. The recommended file system is XFS and you should
disable the last access time file attribute (`noatime` mount option) to further improve the performance.

Ideally, replication factor and retention policy should be set properly when provisioning a new cluster/topic, based on
requirements and the expected volume of messages (GB/s), so that the Kafka never runs out of space. A non active segment
can be deleted based on `segment.ms` or `segment.bytes`. Even if one record is not yet eligible for deletion based
on `retention.ms` or `retention.bytes` (whichever comes first), the broker will keep the entire segment file. Deletion
timing also depends on the cluster load and how many `background.threads` are available in case of normal topics,
and `log.cleaner.threads` in case of compacted topics.

The amount of needed storage capacity can be calculated based on the message retention. For topics with time based
retention, you can calculate the required storage capacity
as `storage_capacity (MB) = retention_sec * topic_write_rate (MB/s) * replication_factor`, while for topics with size
based retention it is `storage_capacity (MB) = retention_mb * replication_factor * part_number`. When the topic combines
both the time and size based retention policies, the size based policy defines the upper cap.

On OpenShift, `PersistentVolume` (PV) resources are claimed using `PersistentVolumeClaim` (PVC) resources. You can
specify the `StorageClass` used to provision the persistent volumes directly in the `Kafka` custom resource. Streams
support increasing the size of persistent volumes, but this must be supported by the infrastructure. Only volumes
created and managed by a `StorageClass` with `allowVolumeExpansion: true` can be increased, but not decreased. With
JBOD, you can also remove a volume, but data needs to be migrated to other volumes upfront.

Note that the following procedure may lead to data loss if not executed correctly. Another cause of service disruption
or data loss is deleting Strimzi CRDs, which would cause the deletion of all deployed Kafka clusters on that OpenShift
cluster by garbage collection mechanism.

### No space left on device

[Deploy the Streams operator and Kafka cluster](/sessions/001). Once the cluster is ready, we break it by sending 14 GiB
of data to a topic with RF=3, which exceeds the total available cluster disk capacity of 30 GiB.

```
$ kubectl get pvc | grep kafka
data-my-cluster-kafka-0       Bound    pvc-8c21101b-a7d0-4b57-922b-d79f0207ffdc   10Gi       RWO            gp2            28m
data-my-cluster-kafka-1       Bound    pvc-100f7351-9d2c-4048-b3a4-e04685a3cd3d   10Gi       RWO            gp2            28m
data-my-cluster-kafka-2       Bound    pvc-65550116-3ae6-4f4f-9be9-a098cdc49002   10Gi       RWO            gp2            28m

$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0-5" -- \
    bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 150000000 \
      --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
If you don't see a command prompt, try pressing enter.
977529 records sent, 195505.8 records/sec (18.64 MB/sec), 156.6 ms avg latency, 486.0 ms max latency.
847415 records sent, 169483.0 records/sec (16.16 MB/sec), 28.1 ms avg latency, 98.0 ms max latency.
827921 records sent, 165584.2 records/sec (15.79 MB/sec), 27.4 ms avg latency, 101.0 ms max latency.
...
[2022-09-21 16:08:25,134] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.131.0.28:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-09-21 16:08:25,583] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.128.2.49:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-09-21 16:08:25,805] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.129.2.61:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
^Cpod "producer-perf" deleted
pod test/producer-perf terminated (Error)

$ kubectl get po | grep kafka
my-cluster-kafka-0                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-1                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-2                            0/1     CrashLoopBackOff   3 (20s ago)   15m

$  kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

If volume expansion is supported, you can simply edit the `Kafka` CR increasing the disk size and the operator will do
the rest (this may take some time). We didn't specify any storage class, so we have been assigned the default one, which
support expansion.

```
$ kubectl get pv pvc-100f7351-9d2c-4048-b3a4-e04685a3cd3d -o yaml | yq e '.spec.storageClassName'
gp2

$ kubectl get sc gp2 -o yaml | yq e '.allowVolumeExpansion'
true


kafka.kafka.strimzi.io/my-cluster patched

$ kubectl -n openshift-operators logs $(kubectl -n openshift-operators get po | grep cluster-operator | cut -d" " -f1) | grep "Resizing"
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-0 from 10 to 20Gi.
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-1 from 10 to 20Gi.
2022-09-21 16:21:44 INFO  KafkaAssemblyOperator:2915 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-2 from 10 to 20Gi.

$ kubectl get pvc | grep kafka
data-my-cluster-kafka-0       Bound    pvc-8c21101b-a7d0-4b57-922b-d79f0207ffdc   20Gi       RWO            gp2            33m
data-my-cluster-kafka-1       Bound    pvc-100f7351-9d2c-4048-b3a4-e04685a3cd3d   20Gi       RWO            gp2            33m
data-my-cluster-kafka-2       Bound    pvc-65550116-3ae6-4f4f-9be9-a098cdc49002   20Gi       RWO            gp2            33m

$ kubectl get po | grep kafka
my-cluster-kafka-0                            1/1     Running   0             2m22s
my-cluster-kafka-1                            1/1     Running   0             3m37s
my-cluster-kafka-2                            1/1     Running   0             4m53s
```

If volume expansion is not supported, the only alternative is to mount the volume and manually delete old segments. This
a risky procedure and should only be applied by experts as last resort and with a recent backup of the entire cluster.
I'm only showing how to do it on one broker-0 here, but this should be done for every broker pod. Once you are done with
all partitions and brokers, you can scale up again and unpause the operator (last 3 commands).

```
$ kubectl annotate k my-cluster strimzi.io/pause-reconciliation="true"
kafka.kafka.strimzi.io/my-cluster annotated

$ kubectl scale sts my-cluster-kafka --replicas=0
statefulset.apps/my-cluster-kafka scaled

$ kubectl run client-$(date +%s) --image "dummy" --restart "Never" \
  --overrides "$(sed "s,#VALUE0#,data-my-cluster-kafka-0,g" sessions/006/patch.json)"
pod/strimzi-debug created

$ kubectl exec -it strimzi-debug -- bash
[root@strimzi-debug /]# cd /data/kafka-log0/my-topic-0
[root@strimzi-debug my-topic-0]# ls -lh 
total 3.3G
-rw-rw-r--. 1 1000660000 1000660000 321K Sep 23 07:49 00000000000000000000.index
-rw-rw-r--. 1 1000660000 1000660000 1.0G Sep 23 07:49 00000000000000000000.log
-rw-rw-r--. 1 1000660000 1000660000 340K Sep 23 07:49 00000000000000000000.timeindex
-rw-rw-r--. 1 1000660000 1000660000 381K Sep 23 07:51 00000000000009703326.index
-rw-rw-r--. 1 1000660000 1000660000 1.0G Sep 23 07:51 00000000000009703326.log
-rw-rw-r--. 1 1000660000 1000660000   10 Sep 23 07:49 00000000000009703326.snapshot
-rw-rw-r--. 1 1000660000 1000660000 392K Sep 23 07:51 00000000000009703326.timeindex
-rw-rw-r--. 1 1000660000 1000660000 414K Sep 23 07:53 00000000000019401640.index
-rw-rw-r--. 1 1000660000 1000660000 1.0G Sep 23 07:53 00000000000019401640.log
-rw-rw-r--. 1 1000660000 1000660000   10 Sep 23 07:51 00000000000019401640.snapshot
-rw-rw-r--. 1 1000660000 1000660000 422K Sep 23 07:53 00000000000019401640.timeindex
-rw-rw-r--. 1 1000660000 1000660000  10M Sep 23 07:53 00000000000029095294.index
-rw-rw-r--. 1 1000660000 1000660000 296M Sep 23 07:53 00000000000029095294.log
-rw-rw-r--. 1 1000660000 1000660000   10 Sep 23 07:53 00000000000029095294.snapshot
-rw-rw-r--. 1 1000660000 1000660000  10M Sep 23 07:53 00000000000029095294.timeindex
-rw-rw-r--. 1 1000660000 1000660000    8 Sep 23 07:47 leader-epoch-checkpoint
-rw-rw-r--. 1 1000660000 1000660000   43 Sep 23 07:45 partition.metadata
[root@strimzi-debug my-topic-0]# rm -f 00000000000000000000.* 00000000000009703326.* 00000000000019401640.*
[root@strimzi-debug my-topic-0]# ls -lh
total 297M
-rw-rw-r--. 1 1000660000 1000660000  10M Sep 23 07:53 00000000000029095294.index
-rw-rw-r--. 1 1000660000 1000660000 296M Sep 23 07:53 00000000000029095294.log
-rw-rw-r--. 1 1000660000 1000660000   10 Sep 23 07:53 00000000000029095294.snapshot
-rw-rw-r--. 1 1000660000 1000660000  10M Sep 23 07:53 00000000000029095294.timeindex
-rw-rw-r--. 1 1000660000 1000660000    8 Sep 23 07:47 leader-epoch-checkpoint
-rw-rw-r--. 1 1000660000 1000660000   43 Sep 23 07:45 partition.metadata

# ...

[root@strimzi-debug my-topic-0]# exit
$ kubectl delete pod strimzi-debug
pod "strimzi-debug" deleted

# ...

$ kubectl scale sts my-cluster-kafka --replicas=3
statefulset.apps/my-cluster-kafka scaled

$ kubectl annotate k my-cluster strimzi.io/pause-reconciliation-
kafka.kafka.strimzi.io/my-cluster annotated

$ kubectl get po | grep kafka
my-cluster-kafka-0                            1/1     Running   0          18m
my-cluster-kafka-1                            1/1     Running   0          18m
my-cluster-kafka-2                            1/1     Running   0          18m
```

### Unintentional namespace deletion with retained volumes

The following procedure helps in cases where the namespace has been unintentionally deleted or a whole OpenShift cluster
has been lost, but volumes have been retained (either the persistent volume has `persistentVolumeReclaimPolicy: Retain`,
or their storage class has `reclaimPolicy: Retain`). This is possible because persistent volumes live outside the
namespace.

[Deploy the Streams operator and Kafka cluster](/sessions/001). Once the cluster is ready, let's change the reclaim
policy at the persistent volume level. Also note that the volume status is "Bound"

```
$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-32b4c2cf-e4f1-453b-b86d-498324a3a1fa   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-1   gp2                     10m
pvc-3f8fbc95-0cbe-4e08-88b1-3ed6f339749f   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     8m43s
pvc-8b3e6629-8466-4c83-a47a-c6f12d2d0f4c   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-0   gp2                     10m
pvc-99e25916-b37d-4c72-aeaf-5aadcea6347a   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-2   gp2                     10m
pvc-d64b4012-e8ea-4c5d-b2b0-90730740896f   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     8m43s
pvc-e05bb77e-9bc6-431c-9d59-bf2f5d664d95   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     8m43s

$ for pv in $(kubectl get pv | grep "my-cluster" | awk '{print $1}'); do
  kubectl patch pv $pv --type json -p '
    [{
      "op": "replace",
      "path": "/spec/persistentVolumeReclaimPolicy",
      "value": "Retain"
    }]'
done
persistentvolume/pvc-32b4c2cf-e4f1-453b-b86d-498324a3a1fa patched
persistentvolume/pvc-3f8fbc95-0cbe-4e08-88b1-3ed6f339749f patched
persistentvolume/pvc-8b3e6629-8466-4c83-a47a-c6f12d2d0f4c patched
persistentvolume/pvc-99e25916-b37d-4c72-aeaf-5aadcea6347a patched
persistentvolume/pvc-d64b4012-e8ea-4c5d-b2b0-90730740896f patched
persistentvolume/pvc-e05bb77e-9bc6-431c-9d59-bf2f5d664d95 patched

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-32b4c2cf-e4f1-453b-b86d-498324a3a1fa   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-1   gp2                     11m
pvc-3f8fbc95-0cbe-4e08-88b1-3ed6f339749f   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     9m37s
pvc-8b3e6629-8466-4c83-a47a-c6f12d2d0f4c   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-0   gp2                     11m
pvc-99e25916-b37d-4c72-aeaf-5aadcea6347a   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-2   gp2                     11m
pvc-d64b4012-e8ea-4c5d-b2b0-90730740896f   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     9m37s
pvc-e05bb77e-9bc6-431c-9d59-bf2f5d664d95   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     9m37s
```

Now we send some data, delete the namespace and check if our volumes are still there. As you can see, the volume status
changed from "Bound" to "Released", but we keep some information that is needed when reattaching them (capacity, claim,
storage class).

```
$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0" -- \
    bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
      --topic my-topic
If you don't see a command prompt, try pressing enter.
>hello
>world
>^Cpod "my-producer" deleted
pod test/my-producer terminated (Error)

$ kubectl delete ns test
namespace "test" deleted

$ kubectl get ns test
Error from server (NotFound): namespaces "test" not found

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                              STORAGECLASS   REASON   AGE
pvc-15de615a-af90-4c41-be31-fa25a4388ef6   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-1   gp2                     12m
pvc-3374a8b4-7b37-42ee-b996-7c7722beedbb   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-2   gp2                     12m
pvc-c29a98b1-e8a8-48ac-a837-3874e280b2b9   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-0   gp2                     12m
pvc-c66dd69f-4f46-4fdf-be60-fb4672ab7d0c   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-0       gp2                     10m
pvc-c7fa720d-ad1b-4f2a-91de-40fa2b8d48ee   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-1       gp2                     10m
pvc-df8f24d6-f558-43ad-87f3-a7b578d55725   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-2       gp2                     10m
```

Our data is still there as expected, so now we have to reattach to a new Kafka cluster instance. Before deploying the
new Kafka cluster, we need to create the conditions so that the old volumes are reattached. We crated a script that
collects required data from retained volumes, removes the old `claimRef` metadata and creates the new claims.

```
$ kubectl create ns test
namespace/test created

$ for line in $(kubectl get pv | grep "my-cluster" | awk '{print $1 "#" $2 "#" $6 "#" $7}'); do
  pv="$(echo $line | awk -F'#' '{print $1}')"
  size="$(echo $line | awk -F'#' '{print $2}')"
  pvc="$(echo $line | awk -F'#' '{print $3}' | sed 's|test\/||g')"
  sc="$(echo $line | awk -F'#' '{print $4}')"
  kubectl patch pv "$pv" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  sed "s,#VALUE0#,$pvc,g; s,#VALUE1#,$size,g; s,#VALUE2#,$sc,g; s,#VALUE3#,$pv,g" \
    sessions/006/pvc.yaml | kubectl create -f -
done
persistentvolume/pvc-32b4c2cf-e4f1-453b-b86d-498324a3a1fa patched
persistentvolumeclaim/data-my-cluster-zookeeper-1 created
persistentvolume/pvc-3f8fbc95-0cbe-4e08-88b1-3ed6f339749f patched
persistentvolumeclaim/data-my-cluster-kafka-1 created
persistentvolume/pvc-8b3e6629-8466-4c83-a47a-c6f12d2d0f4c patched
persistentvolumeclaim/data-my-cluster-zookeeper-0 created
persistentvolume/pvc-99e25916-b37d-4c72-aeaf-5aadcea6347a patched
persistentvolumeclaim/data-my-cluster-zookeeper-2 created
persistentvolume/pvc-d64b4012-e8ea-4c5d-b2b0-90730740896f patched
persistentvolumeclaim/data-my-cluster-kafka-0 created
persistentvolume/pvc-e05bb77e-9bc6-431c-9d59-bf2f5d664d95 patched
persistentvolumeclaim/data-my-cluster-kafka-2 created

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-32b4c2cf-e4f1-453b-b86d-498324a3a1fa   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-1   gp2                     19m
pvc-3f8fbc95-0cbe-4e08-88b1-3ed6f339749f   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     18m
pvc-8b3e6629-8466-4c83-a47a-c6f12d2d0f4c   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-0   gp2                     19m
pvc-99e25916-b37d-4c72-aeaf-5aadcea6347a   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-2   gp2                     19m
pvc-d64b4012-e8ea-4c5d-b2b0-90730740896f   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     18m
pvc-e05bb77e-9bc6-431c-9d59-bf2f5d664d95   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     18m
```

Our volumes are "Bound" again and deploying a new Kafka cluster with the same spec as the previous one should reattach
them.

```
$ kubectl create -f sessions/001/cluster
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl run client-$(date +%s) -it --rm --restart="Never" \
  --image="registry.redhat.io/amq7/amq-streams-kafka-31-rhel8:2.1.0" -- \
    bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
      --topic my-topic --from-beginning
If you don't see a command prompt, try pressing enter.
hello
world
^CProcessed a total of 3 messages
pod "my-consumer" deleted
pod test/my-consumer terminated (Error)
```
