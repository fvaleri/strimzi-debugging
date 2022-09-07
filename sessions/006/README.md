## Avoid running out of Kafka disk space using the Strimzi quota plugin

**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/resources 2>/dev/null
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-407897b1-e78d-4946-9549-e6ad4ea0203a   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     65s
pvc-8ef3854a-2904-4d6e-97c6-363310809723   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     65s
pvc-91682338-6168-4934-9a40-2898a61ea4e2   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     65s
```

Only network bandwidth and request rate quotas are supported by the default Kafka quota plugin. 
Instead, the [Strimzi quota plugin](https://github.com/strimzi/kafka-quotas-plugin) allows to set storage limits independent of the number of clients.

The Strimzi Kafka images already contains this plugin.
With the following configuration, all clients will be throttled to 0 when any volume in the cluster has less than 30% available space.
The check interval is set to 5 seconds.

```sh
$ kubectl patch k my-cluster --type=json \
  -p='[{"op": "add", "path": "/spec/kafka/config/client.quota.callback.static.storage.check-interval", "value": "5"}]' \
  && kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      quotas:
        type: strimzi
        minAvailableRatioPerVolume: 0.3'
kafka.kafka.strimzi.io/my-cluster patched
kafka.kafka.strimzi.io/my-cluster patched
```

After that, the cluster operator will roll all brokers to enable the quota plugin.
When the cluster is ready, we try to break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
125904 records sent, 25180.8 records/sec (24.01 MB/sec), 1312.3 ms avg latency, 1632.0 ms max latency.
109216 records sent, 18324.8 records/sec (17.48 MB/sec), 1026.1 ms avg latency, 3532.0 ms max latency.
194864 records sent, 38856.2 records/sec (37.06 MB/sec), 1325.0 ms avg latency, 6412.0 ms max latency.
[2024-07-07 10:25:20,682] WARN [Producer clientId=perf-producer-client] Got error produce response with correlation id 31412 on topic-partition my-topic-0, retrying (2147483646 attempts left). Error: REQUEST_TIMED_OUT. Error Message: Disconnected from node 0 due to timeout (org.apache.kafka.clients.producer.internals.Sender)
...
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120005 ms has passed since batch creation
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120005 ms has passed since batch creation
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120005 ms has passed since batch creation
...
^C
```

At some point, the perf client can't send data anymore, but the cluster is still healthy.

```sh
$ kubectl get po -l strimzi.io/name=my-cluster-kafka
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          14m
my-cluster-kafka-1   1/1     Running   0          12m
my-cluster-kafka-2   1/1     Running   0          13m

$ kubectl exec my-cluster-kafka-0 -- df -h /var/lib/kafka/data \
  && kubectl exec my-cluster-kafka-1 -- df -h /var/lib/kafka/data \
  && kubectl exec my-cluster-kafka-2 -- df -h /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme2n1    976M  737M  224M  77% /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme2n1    976M  737M  224M  77% /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme2n1    976M  737M  224M  77% /var/lib/kafka/data
```

### Online Kafka volume recovery using expansion support

**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/resources 2>/dev/null
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-1035af7e-474f-48f9-8d9d-cf2817714db3   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-0                            gp3-csi        <unset>                          4m29s
pvc-95e63595-d8a4-4995-be9d-112fce5367ee   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-1                            gp3-csi        <unset>                          4m29s
pvc-ad79d436-ceac-4d3c-8daf-797dafa21e01   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-2                            gp3-csi        <unset>                          4m29s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
34209 records sent, 6832.2 records/sec (6.52 MB/sec), 2617.3 ms avg latency, 4400.0 ms max latency.
67920 records sent, 13578.6 records/sec (12.95 MB/sec), 2768.6 ms avg latency, 4655.0 ms max latency.
75824 records sent, 15164.8 records/sec (14.46 MB/sec), 2200.0 ms avg latency, 2563.0 ms max latency.
...
[2024-07-06 09:44:10,089] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.129.2.24:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 09:44:10,191] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.128.2.19:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 09:44:10,354] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.131.0.28:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po -l strimzi.io/name=my-cluster-kafka
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   8 (70s ago)   27m
my-cluster-kafka-1   0/1     CrashLoopBackOff   8 (84s ago)   25m
my-cluster-kafka-2   0/1     CrashLoopBackOff   8 (87s ago)   26m

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
If volume expansion is supported on the storage class, you can simply increase the storage size in the Kafka resource, and the operator will take care of it. 
Note that the expansion operation may take some time to complete, depending on the size of the volume and the available resources in the cluster.

```sh
if [[ $(kubectl get sc $(kubectl get pv | grep data-my-cluster-kafka-0 | awk '{print $7}') -o yaml | yq .allowVolumeExpansion) == "true" ]]; then 
  kubectl patch knp kafka --type merge -p '
    spec:
        storage:
          size: 10Gi'
fi
kafkanodepool.kafka.strimzi.io/kafka patched

$ kubectl logs $(kubectl get po | grep cluster-operator | awk '{print $1}') | grep "Resizing"
2024-07-06 09:48:27 INFO  PvcReconciler:140 - Reconciliation #120(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-0 from 1 to 10Gi.
2024-07-06 09:48:27 INFO  PvcReconciler:140 - Reconciliation #120(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-1 from 1 to 10Gi.
2024-07-06 09:48:27 INFO  PvcReconciler:140 - Reconciliation #120(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-kafka-2 from 1 to 10Gi

$ kubectl get po -l strimzi.io/name=my-cluster-kafka
NAME                 READY   STATUS     RESTARTS      AGE
my-cluster-kafka-0   1/1     Running    0             5m9s
my-cluster-kafka-1   1/1     Running    0             5m9s
my-cluster-kafka-2   1/1     Running    0             5m9ss

$ kubectl get pv | grep my-cluster-kafka
pvc-8eb9ee55-d0c0-470f-b22a-2714b883fb92   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0                            gp3-csi        <unset>                          11m
pvc-938fd066-6f2e-45c1-b006-ab28ca7bd7f1   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2                            gp3-csi        <unset>                          11m
pvc-f8bc69ed-56db-4c5d-abc8-fedf13093128   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1                            gp3-csi        <unset>                          11m
```

## Offline Kafka volume recovery using snapshot support

**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/resources
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created
Error from server (AlreadyExists): error when creating "sessions/001/resources/000-kafka-pool.yaml": kafkanodepools.kafka.strimzi.io "kafka" already exists

$ CLUSTER_NAME="my-cluster" NODE_POOL_NAME="kafka" \
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="10Gi"; kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-1035af7e-474f-48f9-8d9d-cf2817714db3   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-0                            gp3-csi        <unset>                          4m29s
pvc-95e63595-d8a4-4995-be9d-112fce5367ee   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-1                            gp3-csi        <unset>                          4m29s
pvc-ad79d436-ceac-4d3c-8daf-797dafa21e01   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-2                            gp3-csi        <unset>                          4m29s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=$CLUSTER_NAME-$NODE_POOL_NAME-bootstrap:9092
7094 records sent, 1418.8 records/sec (1.35 MB/sec), 1957.6 ms avg latency, 3358.0 ms max latency.
24560 records sent, 4908.1 records/sec (4.68 MB/sec), 5960.3 ms avg latency, 7960.0 ms max latency.
37520 records sent, 7504.0 records/sec (7.16 MB/sec), 5446.2 ms avg latency, 8493.0 ms max latency.
...
[2024-07-06 13:35:52,882] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.128.0.35:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 13:35:53,014] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.129.0.39:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 13:35:53,450] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.128.0.36:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   1 (11s ago)   2m13s
my-cluster-kafka-1   0/1     CrashLoopBackOff   1 (13s ago)   2m13s
my-cluster-kafka-2   0/1     CrashLoopBackOff   1 (11s ago)   2m13s

$ kubectl logs $CLUSTER_NAME-$NODE_POOL_NAME-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get knp $NODE_POOL_NAME -o yaml | yq .spec.storage.deleteClaim) == "false" ]]; then \
  kubectl delete knp $NODE_POOL_NAME && kubectl delete k $CLUSTER_NAME && kubectl delete po -l strimzi.io/cluster=$CLUSTER_NAME; fi
kafkanodepool.kafka.strimzi.io "kafka" deleted
kafka.kafka.strimzi.io "my-cluster" deleted
pod "my-cluster-entity-operator-7bcb5d76f6-79x4b" deleted
pod "my-cluster-kafka-0" deleted
pod "my-cluster-kafka-1" deleted
pod "my-cluster-kafka-2" deleted
```

If volume snapshot is supported, we can take Kafka volume backups and restore them on bigger volumes.
**Note that we are using the default VolumeSnapshotClass and the snapshot may take some time to complete, depending on the size of the volume and the available resources.**

```sh
$ for pod in $KAFKA_PODS; do
echo -e "apiVersion: snapshot.storage.k8s.io/v1                                                 
kind: VolumeSnapshot
metadata:
  name: data-$pod-snapshot
spec:
  source:
    persistentVolumeClaimName: data-$pod" | kubectl create -f -
done
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-0-snapshot created
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-1-snapshot created
volumesnapshot.snapshot.storage.k8s.io/data-my-cluster-kafka-2-snapshot created

$ kubectl get vs | grep $CLUSTER_NAME-$NODE_POOL_NAME
data-my-cluster-kafka-0-snapshot   true         data-my-cluster-kafka-0                           1Gi           csi-aws-vsc     snapcontent-79d4afc7-9db3-45dd-84e3-38bfe20700e4   2m21s          2m21s
data-my-cluster-kafka-1-snapshot   true         data-my-cluster-kafka-1                           1Gi           csi-aws-vsc     snapcontent-8edf5e72-75fc-4401-b3a3-29976f0cd349   2m19s          2m20s
data-my-cluster-kafka-2-snapshot   true         data-my-cluster-kafka-2                           1Gi           csi-aws-vsc     snapcontent-6e0b9b5b-276c-436e-aa1e-2ea41ca2d3f2   2m17s          2m19s
```

Once they are ready, we can delete the old PVCs, and recreate them with bigger size from the snapshots.
We have to use the same resource name that the operator expects, so that the new volumes will be bound on cluster startup.
**Note that restore operations may take some time to complete, depending on the size of the volume and the available resources in the cluster.**

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

$ kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-4bb20d8e-882d-448d-8a05-92f257019214   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1                                         gp3-csi            12s
pvc-a31b9572-5e52-4ef8-907e-d019db262c85   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2                                         gp3-csi            10s
pvc-e7146aa1-9947-4c78-bb4d-ca8b465b7729   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0                                         gp3-csi            15s
```

Deploy the Kafka cluster with our brand new volumes, wait for the cluster to be ready, and try to consume some data.
**Don't forget to adjust the storage size in Kafka custom resource.**
To speed up log recovery and partition synchronization, we can tune recovery threads and replica fetchers.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"10Gi\"" | kubectl create -f - \
  && cat sessions/001/resources/001-my-cluster.yaml \
    | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
    | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" | kubectl create -f -
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                 READY   STATUS     RESTARTS      AGE
my-cluster-kafka-0   1/1     Running    0             5m9s
my-cluster-kafka-1   1/1     Running    0             5m9s
my-cluster-kafka-2   1/1     Running    0             5m9ss

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server $CLUSTER_NAME-$NODE_POOL_NAME-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
FHBQCYJJXEDISRBBOAKYFHTLDAJABMKLWHLRSBWBUSGRIBKSWWZQZHPHWQWZPVHLYBDVYNNOMLSAXDZSDGGQXVDETEXXEXTVNJTNOVJIYIDAFEPCIRHMQJMCRCGNVNIPISAPPHKTVRVF...
MYVZNMKXIYVTRGXHNLAXSIISAKQSPQIJKJMVYXFQVTXJVNPRZILRJKMIEBDWGCRKXFUSMWBLCVCDVXEBMXSLVXZSCPQVRNZTHKGFIBZBCOURYJEGKPJACEXCSQDFBCWXGNYERXKOHJAA...
RHTSTTCCIQLHFTWTCEUZJHADNDIYHMXSCUFDMIQXGISLNYVGNZKIJFDFQJVRWDLUNUTXNLCKSQOZNEYLRAGPFPUQSQWNJWUXLWWCLOHASOMJKNZRYSRXGIWWFTEUWVBIITCFUANCCTNT...
Processed a total of 3 messages
```

## Offline Kafka volume recovery with no expansion and snapshot support

**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/resources
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created
Error from server (AlreadyExists): error when creating "sessions/001/resources/000-kafka-pool.yaml": kafkanodepools.kafka.strimzi.io "kafka" already exists

$ CLUSTER_NAME="my-cluster" NODE_POOL_NAME="kafka" \
  KAFKA_PODS="$(kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME --no-headers -o custom-columns=':metadata.name')" \
  VOLUME_CLASS="$(kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME-0 | awk '{print $7}')" \
  NEW_VOLUME_SIZE="10Gi"; kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-283cf8b4-aa2c-4386-985e-918ab1238248   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     2m4s
pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     2m4s
pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     2m4s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=$CLUSTER_NAME-$NODE_POOL_NAME-bootstrap:9092
43393 records sent, 8678.6 records/sec (8.28 MB/sec), 2429.0 ms avg latency, 3754.0 ms max latency.
44193 records sent, 8808.7 records/sec (8.40 MB/sec), 2321.9 ms avg latency, 3639.0 ms max latency.
73280 records sent, 14656.0 records/sec (13.98 MB/sec), 2387.5 ms avg latency, 3085.0 ms max latency.
...
[2024-07-06 15:42:22,288] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.129.0.33:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 15:42:22,296] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.130.0.20:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-07-06 15:42:22,452] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.131.0.29:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   3 (7s ago)    5m49s
my-cluster-kafka-1   0/1     CrashLoopBackOff   3 (31s ago)   5m49s
my-cluster-kafka-2   0/1     CrashLoopBackOff   3 (10s ago)   5m49s

$ kubectl logs $CLUSTER_NAME-$NODE_POOL_NAME-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get knp $NODE_POOL_NAME -o yaml | yq .spec.storage.deleteClaim) == "false" ]]; then \
  kubectl delete knp $NODE_POOL_NAME && kubectl delete k $CLUSTER_NAME && kubectl delete po -l strimzi.io/cluster=$CLUSTER_NAME; fi
kafkanodepool.kafka.strimzi.io "kafka" deleted
kafka.kafka.strimzi.io "my-cluster" deleted
pod "my-cluster-entity-operator-7bcb5d76f6-79x4b" deleted
pod "my-cluster-kafka-0" deleted
pod "my-cluster-kafka-1" deleted
pod "my-cluster-kafka-2" deleted
```

Create new and bigger volumes for our brokers.
In this case, volumes are created automatically, but you may need to create them manually.
They will be bound only when the first consumer (pod) will be created.

```sh
$ for pod in $KAFKA_PODS; do
  cat sessions/006/resources/pvc-new.yaml \
    | yq ".metadata.name = \"data-$pod-new\" \
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-$NODE_POOL_NAME\" \
      | .spec.storageClassName = \"$VOLUME_CLASS\" \
      | .spec.resources.requests.storage = \"$NEW_VOLUME_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim/data-my-cluster-kafka-0-new created
persistentvolumeclaim/data-my-cluster-kafka-1-new created
persistentvolumeclaim/data-my-cluster-kafka-2-new created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                          STATUS    VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-my-cluster-kafka-0       Bound     pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67   1Gi        RWO            gp2            6m34s
data-my-cluster-kafka-0-new   Pending                                                                        gp2            13s
data-my-cluster-kafka-1       Bound     pvc-283cf8b4-aa2c-4386-985e-918ab1238248   1Gi        RWO            gp2            6m34s
data-my-cluster-kafka-1-new   Pending                                                                        gp2            12s
data-my-cluster-kafka-2       Bound     pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3   1Gi        RWO            gp2            6m34s
data-my-cluster-kafka-2-new   Pending                                                                        gp2            11s
```

**Set the persistent volume reclaim policy to Retain, in order to avoid losing broker data when deleting Kafka PVCs.**

```sh
$ for pv in $(kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME | awk '{print $1}'); do
  kubectl patch pv $pv --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Retain'
done
persistentvolume/pvc-283cf8b4-aa2c-4386-985e-918ab1238248 patched
persistentvolume/pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67 patched
persistentvolume/pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3 patched

$ kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-283cf8b4-aa2c-4386-985e-918ab1238248   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     7m31s
pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     7m31s
pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     7m31s
```

Copy all broker data from the old volumes to the new volumes spinning up a maintenance pod.
**Note that the following commands may take some time, depending on the amount of data they have to copy.**

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

$ kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-0cb6b363-69ad-4fc6-a398-7d464aed9cb2   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2-new   gp2                     26s
pvc-27db6379-269a-4578-bc14-e887a673b67c   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1-new   gp2                     51s
pvc-283cf8b4-aa2c-4386-985e-918ab1238248   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-1       gp2                     9m14s
pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-0       gp2                     9m14s
pvc-d9596016-4bed-4cd6-b660-c854763c64e9   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0-new   gp2                     78s
pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3   1Gi        RWO            Retain           Bound    test/data-my-cluster-kafka-2       gp2                     9m14s
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
      | .metadata.labels.\"strimzi.io/name\" = \"$CLUSTER_NAME-$NODE_POOL_NAME\" \
      | .spec.storageClassName = \"$VOLUME_CLASS\" \
      | .spec.volumeName = \"$NEW_PV_NAME\" \
      | .spec.resources.requests.storage = \"$NEW_VOLUME_SIZE\"" \
    | kubectl create -f -
done
persistentvolumeclaim "data-my-cluster-kafka-0" deleted
persistentvolumeclaim "data-my-cluster-kafka-0-new" deleted
persistentvolume/pvc-89c07b6c-4202-48dc-8a84-2b6f0faf2b67 patched
persistentvolume/pvc-d9596016-4bed-4cd6-b660-c854763c64e9 patched
persistentvolumeclaim/data-my-cluster-kafka-0 created
persistentvolumeclaim "data-my-cluster-kafka-1" deleted
persistentvolumeclaim "data-my-cluster-kafka-1-new" deleted
persistentvolume/pvc-27db6379-269a-4578-bc14-e887a673b67c patched
persistentvolume/pvc-283cf8b4-aa2c-4386-985e-918ab1238248 patched
persistentvolumeclaim/data-my-cluster-kafka-1 created
persistentvolumeclaim "data-my-cluster-kafka-2" deleted
persistentvolumeclaim "data-my-cluster-kafka-2-new" deleted
persistentvolume/pvc-0cb6b363-69ad-4fc6-a398-7d464aed9cb2 patched
persistentvolume/pvc-ff98350c-2b4d-4406-8807-1d1cdfc7afd3 patched
persistentvolumeclaim/data-my-cluster-kafka-2 created

$ kubectl get pvc -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-my-cluster-kafka-0   Bound    pvc-d9596016-4bed-4cd6-b660-c854763c64e9   10Gi       RWO            gp2            29s
data-my-cluster-kafka-1   Bound    pvc-27db6379-269a-4578-bc14-e887a673b67c   10Gi       RWO            gp2            25s
data-my-cluster-kafka-2   Bound    pvc-0cb6b363-69ad-4fc6-a398-7d464aed9cb2   10Gi       RWO            gp2            21s
```

Deploy the Kafka cluster with our brand new volumes, wait for the cluster to be ready, and try to consume some data.
**Don't forget to adjust the storage size in Kafka custom resource.**
To speed up log recovery and partition synchronization, we can tune recovery threads and replica fetchers.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"10Gi\"" | kubectl create -f - \
  && cat sessions/001/resources/001-my-cluster.yaml \
    | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
    | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" | kubectl create -f -
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created

$ kubectl get po -l strimzi.io/name=$CLUSTER_NAME-$NODE_POOL_NAME
NAME                 READY   STATUS    RESTARTS   AGE
my-cluster-kafka-0   1/1     Running   0          2m27s
my-cluster-kafka-1   1/1     Running   0          2m27s
my-cluster-kafka-2   1/1     Running   0          2m27s

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server $CLUSTER_NAME-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
XVFTWDJKAIYRBIKZRFOEZNWURGQHGPDMOZYAEBTFLNCXMVOJOCPCXZLUZJKPTIFQVRHWKHBMTMHFHJGAIXNWURPJOKMXRAWLHMUNNWVYSNPIMZXJDKSLVMLJYZFJCQOIQXNFLYYYTEFK...
FVABXPFDUNYNYMNVYWZDVZLGZASDYATOWNFMRODUPWCUVVIZFRLZNDOSQWZVNGMGEYHDVAWZDQLXBAIZGFDUOKGGHDBTLOJLMLPXTPXXZZQXFIVTAZOHHGWJBUSMPKIPCMOAJVSLUYGJ...
OAPJJFCTIWBLZMWUVMWRSGJQMXVLATYRECKCHDEIHYOMLCLKAULDWNSRIXKVWSNHLJUADUZNUMCJQYASBCSJWHIKXLATGMGNENPSSVIUAWSRRABUBXFZZRKOGOFGTBVIWTWFUWHEEMGF...
Processed a total of 3 messages
```

Finally, we delete the old volumes to reclaim some space.

```sh
$ kubectl delete pv $(kubectl get pv | grep Available | awk '{print $1}')
persistentvolume "pvc-04b55551-fe7f-4662-9955-5e4baaf4df57" deleted
persistentvolume "pvc-18280833-16a8-4cd5-8c6f-eb764acd3ce9" deleted
persistentvolume "pvc-a148ee8b-2eef-422b-a35e-b71714b1ef85" deleted

$ kubectl get pv | grep $CLUSTER_NAME-$NODE_POOL_NAME
pvc-0cb6b363-69ad-4fc6-a398-7d464aed9cb2   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-2       gp2                     12m
pvc-27db6379-269a-4578-bc14-e887a673b67c   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-1       gp2                     13m
pvc-d9596016-4bed-4cd6-b660-c854763c64e9   10Gi       RWO            Delete           Bound    test/data-my-cluster-kafka-0       gp2                     13m
```

## Offline Kafka volume recovery without additional storage

**Don't use Minikube, as it doesn't have full volume support.**

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster with 1 MiB as maximum segment size, and reducing the volume size.

```sh
$ cat sessions/001/resources/000-kafka-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && cat sessions/001/resources/001-my-cluster.yaml \
    | yq ".spec.kafka.config.\"log.segment.bytes\" = 1048576" | kubectl create -f - \
  && kubectl create -f sessions/001/resources/002-my-topic.yaml
kafkanodepool.kafka.strimzi.io/kafka created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-kafka
pvc-1035af7e-474f-48f9-8d9d-cf2817714db3   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-0                            gp3-csi        <unset>                          4m29s
pvc-95e63595-d8a4-4995-be9d-112fce5367ee   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-1                            gp3-csi        <unset>                          4m29s
pvc-ad79d436-ceac-4d3c-8daf-797dafa21e01   1Gi        RWO            Delete           Bound    test/data-my-cluster-kafka-2                            gp3-csi        <unset>                          4m29s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
12689 records sent, 2514.7 records/sec (2.40 MB/sec), 2329.9 ms avg latency, 4480.0 ms max latency.
14688 records sent, 2937.6 records/sec (2.80 MB/sec), 6876.8 ms avg latency, 9398.0 ms max latency.
14720 records sent, 2941.1 records/sec (2.80 MB/sec), 10612.5 ms avg latency, 12127.0 ms max latency.
...
[2024-02-28 10:59:21,306] WARN [Producer clientId=perf-producer-client] Connection to node 0 (my-cluster-kafka-0.my-cluster-kafka-brokers.test.svc/10.135.0.71:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-02-28 10:59:21,309] WARN [Producer clientId=perf-producer-client] Connection to node 2 (my-cluster-kafka-2.my-cluster-kafka-brokers.test.svc/10.134.0.38:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-02-28 10:59:21,330] WARN [Producer clientId=perf-producer-client] Connection to node 1 (my-cluster-kafka-1.my-cluster-kafka-brokers.test.svc/10.132.2.42:9092) could not be established. Broker may not be available. (org.apache.kafka.clients.NetworkClient)
...

$ kubectl get po -l strimzi.io/name=my-cluster-kafka
NAME                 READY   STATUS             RESTARTS      AGE
my-cluster-kafka-0   0/1     CrashLoopBackOff   1 (11s ago)   2m13s
my-cluster-kafka-1   0/1     CrashLoopBackOff   1 (13s ago)   2m13s
my-cluster-kafka-2   0/1     CrashLoopBackOff   1 (11s ago)   2m13s

$ kubectl logs my-cluster-kafka-0 | grep "No space left on device" | tail -n1
java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.
**Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.**

```sh
$ if [[ $(kubectl get knp kafka -o yaml | yq .spec.storage.deleteClaim) == "false" ]]; then \
  kubectl delete knp kafka && kubectl delete k my-cluster && kubectl delete po -l strimzi.io/cluster=my-cluster; fi
kafkanodepool.kafka.strimzi.io "kafka" deleted
kafka.kafka.strimzi.io "my-cluster" deleted
pod "my-cluster-entity-operator-7bcb5d76f6-79x4b" deleted
pod "my-cluster-kafka-0" deleted
pod "my-cluster-kafka-1" deleted
pod "my-cluster-kafka-2" deleted
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

## Online ZooKeeper recovery from corrupted storage with quorum loss

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
