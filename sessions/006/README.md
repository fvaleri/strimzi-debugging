# Storage requirements and volume recovery

Kafka requires low latency storage to store both broker commit logs and ZooKeeper data.
File storage like NFS does not work well (silly rename problem).
Both Kafka and Zookeeper have built-in data replication, so they do not need replicated storage to ensure data availability, which would only add network overhead.
Streams can also work with network attached block storage, such as iSCSI or Fibre Channel, and with most block storage services such as Amazon EBS.
You can also use JBOD (just a bunch of disks), that gives good performance when using multiple disk in parallel.
The recommended file system is XFS.
An easy optimization is to disable the last access time file attribute (noatime).

Ideally, the retention policy should be set properly when provisioning a new cluster or topic, based on requirements and the expected throughput (MB/s).
A non active segment can be deleted based on `segment.ms` or `segment.bytes`.
Even if one record is not yet eligible for deletion based on `retention.ms` or `retention.bytes`, the broker will keep the entire segment file.
Deletion timing also depends on the cluster load and how many `background.threads` are available for normal topics, and `log.cleaner.threads` for compacted topics.
The required storage capacity can be calculated based on the message retention.
When the topic combines both time and size based retention policies, the size based policy defines the upper cap.

```sh
# time based retention
storage_capacity (MB) = retention_sec * topic_write_rate (MB/s) * replication_factor

# size based retention
storage_capacity (MB) = retention_mb * replication_factor * part_number
```

In OpenShift, a persistent volume (PV) lives outside any namespace, and it is claimed by using a persistent volume claim (PVC).
You can specify the storage class (SC) used for provisioning directly in the Kafka CR.
Only volumes created and managed by a SC with `allowVolumeExpansion: true` can be increased, but not decreased.
When using JBOD, you can also remove a volume, but data needs to be migrated to other volumes upfront.
Volumes with either `persistentVolumeReclaimPolicy: Retain`, or using a storage class with `reclaimPolicy: Retain` are retained when the Kafka cluster is deleted.

# Example: no space left on device

[Deploy Streams operator and Kafka cluster](/sessions/001). 
When the cluster is ready, we purposely break it by sending 11 GiB of data to a topic with RF=3 (33 GiB in total), which exceeds the combined cluster disk capacity of 30 GiB.

```sh
$ kubectl get pv | grep kafka
pvc-2e3c7665-2b92-4376-bb1d-22b1d23fcc6a   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     4m1s
pvc-b1e5e0a3-ab83-487f-9b81-c38e1badfccc   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     4m1s
pvc-e66030cd-3992-4adc-9d94-d9d4ab164a45   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     4m1s

$ kube-rkc kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 12000000 \
  --throughput -1 --producer-props acks=1 bootstrap.servers=my-cluster-kafka-bootstrap:9092
287699 records sent, 57528.3 records/sec (54.86 MB/sec), 144.6 ms avg latency, 455.0 ms max latency.
309618 records sent, 61923.6 records/sec (59.05 MB/sec), 29.1 ms avg latency, 132.0 ms max latency.
301344 records sent, 60268.8 records/sec (57.48 MB/sec), 53.2 ms avg latency, 361.0 ms max latency.
...
[2022-10-14 15:14:26,695] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.128.2.32:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-10-14 15:14:26,885] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.129.2.59:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2022-10-14 15:14:27,036] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.131.0.37:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
^Cpod "rkc-1665760296" deleted

$ kubectl get po | grep kafka
my-cluster-kafka-0                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-1                            0/1     CrashLoopBackOff   3 (26s ago)   15m
my-cluster-kafka-2                            0/1     CrashLoopBackOff   3 (20s ago)   15m

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

If volume expansion is supported, you can simply edit the Kafka CR increasing the disk size and the operator will do the rest (this may take some time).
We didn't specify any storage class, so we have been assigned the default one.

```sh
$ kubectl get sc $(kubectl get pv | grep data-my-cluster-kafka-0 | awk '{print $7}') -o yaml | yq '.allowVolumeExpansion'
true

$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      storage:
        size: 20Gi'
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl -n openshift-operators logs $(kubectl -n openshift-operators get po | grep cluster-operator | cut -d" " -f1) | grep "Resizing"
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

If volume expansion is not supported, the only alternative is to mount the volume and manually delete old segments.
This a risky procedure and should only be applied by experts as a last resort and having a recent cluster backup.
I'm only showing how to do it on broker-0, but this should be done for every broker.
Once you are done with all partitions, you can scale up again and unpause the cluster operator.

A similar technique can also be used to copy data to your local disk and from there to new and bigger volumes.

```sh
$ kubectl annotate k my-cluster strimzi.io/pause-reconciliation="true" \
  && kubectl scale sts my-cluster-kafka --replicas=0
kafka.kafka.strimzi.io/my-cluster annotated
statefulset.apps/my-cluster-kafka scaled

$ kubectl run recovery --image "dummy" --restart "Never" \
  --overrides "$(sed "s,value0,data-my-cluster-kafka-0,g" sessions/006/resources/patch.json)"
pod/recovery created

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
$ kubectl delete pod recovery
pod "recovery" deleted

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

# Example: unintentional cluster deletion with retained volumes

The Streams examples have `.spec.kafka.storage.deleteClaim: false`, which is also the default value. 
This means that the PVC are not deleted when the cluster is undeployed, but the user may have changed that.
In this case, they lose all data by garbage collection if someone deletes the CRDs or the namespace by mistake.
That said, if the PV reclaim policy is set to retain, there is still hope to recover them.

[Deploy Streams operator and Kafka cluster](/sessions/001).
When the cluster is ready, we change the reclaim policy at the persistent volume level.
Also note that the status is "Bound".

```sh
$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-162c6551-f05f-4c89-9319-637a4b3d417c   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-1   gp2                     2m50s
pvc-3c131641-dca8-4648-8cfb-ea844145a5a3   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-2   gp2                     2m50s
pvc-566ffb72-4b5e-454e-8e40-03877f0100e5   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     79s
pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     79s
pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     79s
pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0   5Gi        RWO            Delete           Bound    test/data-my-cluster-zookeeper-0   gp2                     2m50s

$ for pv in $(kubectl get pv | grep "my-cluster" | awk '{print $1}'); do
  kubectl patch pv $pv --type merge -p '
    metadata:
      labels:
        app: retain-patch
    spec:
      persistentVolumeReclaimPolicy: Retain'
done
persistentvolume/pvc-162c6551-f05f-4c89-9319-637a4b3d417c patched
persistentvolume/pvc-3c131641-dca8-4648-8cfb-ea844145a5a3 patched
persistentvolume/pvc-566ffb72-4b5e-454e-8e40-03877f0100e5 patched
persistentvolume/pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7 patched
persistentvolume/pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91 patched
persistentvolume/pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0 patched

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-162c6551-f05f-4c89-9319-637a4b3d417c   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-1   gp2                     3m22s
pvc-3c131641-dca8-4648-8cfb-ea844145a5a3   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-2   gp2                     3m22s
pvc-566ffb72-4b5e-454e-8e40-03877f0100e5   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     111s
pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     111s
pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     111s
pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-0   gp2                     3m22s
```

Now we send some data and then delete the entire namespace by mistake.
As expected, all persistent volumes are still there after the namespace deletion, and their status changed to "Released".
Note that OpenShift also retains some useful information that is needed when reattaching them (capacity, claim, storage class).

```sh
$ kube-rkc kafka-console-producer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
aaa
>bbb
>ccc
>^C

$ kubectl delete ns test
namespace "test" deleted

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                              STORAGECLASS   REASON   AGE
pvc-162c6551-f05f-4c89-9319-637a4b3d417c   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-1   gp2                     5m48s
pvc-3c131641-dca8-4648-8cfb-ea844145a5a3   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-2   gp2                     5m48s
pvc-566ffb72-4b5e-454e-8e40-03877f0100e5   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-2       gp2                     4m17s
pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-0       gp2                     4m17s
pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91   10Gi       RWO            Retain           Released   test/data-my-cluster-kafka-1       gp2                     4m17s
pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0   5Gi        RWO            Retain           Released   test/data-my-cluster-zookeeper-0   gp2                     5m48s
```

We need to create the conditions so that the old volumes can be reattached by the new Streams cluster.
We use a simple script to collect all required data from the retained PVs, remove the old `claimRef` metadata and create the new PVCs.
Volumes are "Bound" again, and they should be reattached if we deploy a new Kafka cluster with the same configuration.

```sh
$ kubectl create ns test
namespace/test created

$ for line in $(kubectl get pv | grep "my-cluster" | awk '{print $1 "#" $2 "#" $6 "#" $7}'); do
  pvc="$(echo $line | awk -F'#' '{print $3}' | sed 's|test\/||g')"
  size="$(echo $line | awk -F'#' '{print $2}')"
  sc="$(echo $line | awk -F'#' '{print $4}')"
  pv="$(echo $line | awk -F'#' '{print $1}')"
  kubectl patch pv "$pv" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  sed "s#value0#$pvc#g; s#value1#$size#g; s#value2#$sc#g; s#value3#$pv#g" \
    sessions/006/resources/pvc.yaml | kubectl create -f -
done
persistentvolume/pvc-162c6551-f05f-4c89-9319-637a4b3d417c patched
persistentvolumeclaim/data-my-cluster-zookeeper-1 created
persistentvolume/pvc-3c131641-dca8-4648-8cfb-ea844145a5a3 patched
persistentvolumeclaim/data-my-cluster-zookeeper-2 created
persistentvolume/pvc-566ffb72-4b5e-454e-8e40-03877f0100e5 patched
persistentvolumeclaim/data-my-cluster-kafka-2 created
persistentvolume/pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7 patched
persistentvolumeclaim/data-my-cluster-kafka-0 created
persistentvolume/pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91 patched
persistentvolumeclaim/data-my-cluster-kafka-1 created
persistentvolume/pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0 patched
persistentvolumeclaim/data-my-cluster-zookeeper-0 created

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                              STORAGECLASS   REASON   AGE
pvc-162c6551-f05f-4c89-9319-637a4b3d417c   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-1   gp2                     6m37s
pvc-3c131641-dca8-4648-8cfb-ea844145a5a3   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-2   gp2                     6m37s
pvc-566ffb72-4b5e-454e-8e40-03877f0100e5   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     5m6s
pvc-8587e7b0-bedd-494c-b43f-0f249cec03c7   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     5m6s
pvc-c2cb8453-b953-4bb1-83b5-f4e4c76fbf91   10Gi       RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     5m6s
pvc-f5b75d58-b621-4cf9-8c5c-2e9215b268e0   5Gi        RWO            Retain           Bound    test/data-my-cluster-zookeeper-0   gp2                     6m37s
```

Now we can deploy the new Stream cluster.
Note that this is actually the same Kafka cluster, because retained volumes maintain the same Kafka cluster ID.

Important: before deploying the TO, we must delete its internal topics so that it can safely reinitialize from Kafka on startup.
If you don't do this, there is a high change that the TO will delete all topics with your data.
Topic deletion happens asinchronously, so always make sure to confirm that it is actually deleted.

```sh
$ cat sessions/001/resources/000-my-cluster.yaml | yq 'del(.spec.entityOperator.topicOperator)' | kubectl create -f -
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kube-rkc kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --list
__consumer_offsets
__strimzi-topic-operator-kstreams-topic-store-changelog
__strimzi_store_topic
my-topic

$ for topic in "__strimzi_store_topic" ".*topic-store-changelog"; do
  kube-rkc kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic $topic --delete
done
  
$ kube-rkc kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 --list
__consumer_offsets
my-topic
```

When these topics are deleted, we can safely deploy the TO and try to consume our messages from the restored cluster.

```sh
$ kubectl apply -f sessions/001/resources/000-my-cluster.yaml
kafka.kafka.strimzi.io/my-cluster configured

$ kubectl get kt my-topic -o yaml | yq '.status'
conditions:
  - lastTransitionTime: "2022-10-27T15:04:21.052978Z"
    status: "True"
    type: Ready
observedGeneration: 1
topicName: my-topic

# drumroll
$ kube-rkc kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning
bbb
aaa
ccc
^CProcessed a total of 3 messages
```
