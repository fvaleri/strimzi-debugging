## Storage requirements and volume recovery

Kafka requires **low latency storage** to store both broker commit logs and ZooKeeper data. File storage like NFS does
not work well (silly rename problem). Both Kafka and Zookeeper have **built-in data replication**, so they do not need
replicated storage to ensure data availability, which would only add network overhead. Streams can also work with
network attached block storage, such as iSCSI or Fibre Channel, and with most block storage services such as Amazon EBS.
You can also use JBOD (just a bunch of disks), that gives good performance when using multiple disk in parallel. The
recommended file system is XFS. An easy optimization is to disable the last access time file attribute (noatime).

Ideally, the **retention policy** should be set properly when provisioning a new cluster or topic, based on requirements
and the expected volume of messages (GB/s). A non active segment can be deleted based on `segment.ms` or
`segment.bytes`. Even if one record is not yet eligible for deletion based on `retention.ms` or `retention.bytes`, the
broker will keep the entire segment file. Deletion timing also depends on the cluster load and how
many `background.threads` are available for normal topics, and `log.cleaner.threads` for compacted topics. The required
storage capacity can be calculated based on the message retention. When the topic combines both the time and size based
retention policies, the size based policy defines the upper cap.

```sh
# time based retention
storage_capacity (MB) = retention_sec * topic_write_rate (MB/s) * replication_factor

# size based retention
storage_capacity (MB) = retention_mb * replication_factor * part_number
```

In OpenShift, a persistent volume (PV) lives outside any namespace and it is claimed by using a persistent volume claim
(PVC). You can specify the storage class (SC) used for provisioning directly in the Kafka CR. Only volumes created and
managed by a SC with `allowVolumeExpansion: true` can be increased, but not decreased. When using JBOD, you can also
remove a volume, but data needs to be migrated to other volumes upfront. Volumes with
either `persistentVolumeReclaimPolicy: Retain`, or using a storage class with `reclaimPolicy: Retain` are retained when
the Kafka cluster is deleted.

### Example: no space left on device

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, we break it by sending 14 GiB of
data to a topic with RF=3, which exceeds the combined cluster disk capacity of 30 GiB.

```sh
$ kubectl get pvc | grep kafka
data-my-cluster-kafka-0       Bound    pvc-8c21101b-a7d0-4b57-922b-d79f0207ffdc   10Gi       RWO            gp2            28m
data-my-cluster-kafka-1       Bound    pvc-100f7351-9d2c-4048-b3a4-e04685a3cd3d   10Gi       RWO            gp2            28m
data-my-cluster-kafka-2       Bound    pvc-65550116-3ae6-4f4f-9be9-a098cdc49002   10Gi       RWO            gp2            28m

$ krun_kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 100 --num-records 150000000 \
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

If volume expansion is supported, you can simply edit the Kafka CR increasing the disk size and the operator will do the
rest (this may take some time). We didn't specify any storage class, so we have been assigned the default one.

```sh
$ kubectl get pv pvc-100f7351-9d2c-4048-b3a4-e04685a3cd3d -o yaml | yq e '.spec.storageClassName'
gp2

$ kubectl get sc gp2 -o yaml | yq e '.allowVolumeExpansion'
true

$ kubectl patch k my-cluster --type json -p '
  [{
    "op": "replace",
    "path": "/spec/kafka/storage/size",
    "value": "20Gi"
  }]'
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
a risky procedure and should only be applied by experts as a last resort and having a recent cluster backup. I'm only
showing how to do it on broker-0, but this should be done for every broker. Once you are done with all partitions, you
can scale up again and unpause the cluster operator.

```sh
$ kubectl annotate k my-cluster strimzi.io/pause-reconciliation="true" \
  && kubectl scale sts my-cluster-kafka --replicas=0
kafka.kafka.strimzi.io/my-cluster annotated
statefulset.apps/my-cluster-kafka scaled

$ kubectl run client-$(date +%s) --image "dummy" --restart "Never" \
  --overrides "$(sed "s,value0,data-my-cluster-kafka-0,g" sessions/006/patch.json)"
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

$ kubectl scale sts my-cluster-kafka --replicas=3 \
  && kubectl annotate k my-cluster strimzi.io/pause-reconciliation-
statefulset.apps/my-cluster-kafka scaled
kafka.kafka.strimzi.io/my-cluster annotated

$ kubectl get po | grep kafka
my-cluster-kafka-0                            1/1     Running   0          18m
my-cluster-kafka-1                            1/1     Running   0          18m
my-cluster-kafka-2                            1/1     Running   0          18m
```

### Example: unintentional namespace deletion with retained volumes

[Deploy Streams operator and Kafka cluster](/sessions/001). When the cluster is ready, we change the reclaim policy at
the persistent volume level. Also note that the volume status is "Bound".

```sh
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

Now we send some data and then delete the namespace. As expected, persistent volumes are still there and their status
changed from "Bound" to "Released". Note that we also retain some useful information that is needed when reattaching
them (capacity, claim, storage class).

```sh
$ krun_kafka bin/kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
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

Before deploying a new Kafka cluster, we need to create the conditions so that the old volumes are reattached. We use a
simple script to collect required data, remove the old `claimRef` metadata and create the new volume claims.

```sh
$ kubectl create ns test
namespace/test created

$ for line in $(kubectl get pv | grep "my-cluster" | awk '{print $1 "#" $2 "#" $6 "#" $7}'); do
  pv="$(echo $line | awk -F'#' '{print $1}')"
  size="$(echo $line | awk -F'#' '{print $2}')"
  pvc="$(echo $line | awk -F'#' '{print $3}' | sed 's|test\/||g')"
  sc="$(echo $line | awk -F'#' '{print $4}')"
  kubectl patch pv "$pv" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  sed "s#value0#$pvc#g; s#value1#$size#g; s#value2#$sc#g; s#value3#$pv#g" \
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

Volumes are "Bound" again and deploying a new Kafka cluster with the same spec we should be able to consume messages.

```sh
$ kubectl create -f sessions/001/cluster
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ krun_kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning
If you don't see a command prompt, try pressing enter.
hello
world
^CProcessed a total of 3 messages
pod "my-consumer" deleted
pod test/my-consumer terminated (Error)
```
