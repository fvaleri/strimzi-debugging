## Avoid running out of disk space with the Strimzi quota plugin

> [!WARNING]
> Don't use Minikube, as it uses hostpath volumes that do not enforce storage capacity.

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.

For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/install/001-broker-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/install 2>/dev/null
kafkanodepool.kafka.strimzi.io/broker created
kafkanodepool.kafka.strimzi.io/controller created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-broker
pvc-2609aaa7-3a13-4bc3-9d0a-cc19c4ccef50   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          4m15s
pvc-55f69017-6ef9-4701-94ef-ffb90433cebd   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          4m15s
pvc-741a3a77-9f5a-4656-af71-d41619e12bfc   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          4m15s
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
21873 records sent, 4373.7 records/sec (4.17 MB/sec), 2509.9 ms avg latency, 4285.0 ms max latency.
41344 records sent, 8268.8 records/sec (7.89 MB/sec), 4536.6 ms avg latency, 5997.0 ms max latency.
49104 records sent, 9820.8 records/sec (9.37 MB/sec), 3575.3 ms avg latency, 4295.0 ms max latency.
...
org.apache.kafka.clients.producer.BufferExhaustedException: Failed to allocate 16384 bytes within the configured max blocking time 60000 ms. Total memory: 33554432 bytes. Available memory: 0 bytes. Poolable size: 16384 bytes
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120018 ms has passed since batch creation
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120018 ms has passed since batch creation
org.apache.kafka.common.errors.TimeoutException: Expiring 16 record(s) for my-topic-0:120018 ms has passed since batch creation
...
^C
```

At some point, the perf client can't send data anymore, but the cluster is still healthy.

```sh
$ kubectl get po | grep my-cluster-broker
my-cluster-kafka-7   0/1     CrashLoopBackOff   8 (70s ago)   27m
my-cluster-kafka-8   0/1     CrashLoopBackOff   8 (84s ago)   25m
my-cluster-kafka-9   0/1     CrashLoopBackOff   8 (87s ago)   26m

$ kubectl exec my-cluster-broker-7 -- df -h /var/lib/kafka/data \
  && kubectl exec my-cluster-broker-8 -- df -h /var/lib/kafka/data \
  && kubectl exec my-cluster-broker-9 -- df -h /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1    974M  735M  223M  77% /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1    974M  735M  223M  77% /var/lib/kafka/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1    974M  735M  223M  77% /var/lib/kafka/data
```

## Online Kafka volume recovery with expansion support

> [!WARNING]
> Don't use Minikube, as it uses hostpath volumes that do not enforce storage capacity.

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.

For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/install/001-broker-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/install 2>/dev/null
kafkanodepool.kafka.strimzi.io/broker created
kafkanodepool.kafka.strimzi.io/controller created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl get pv | grep my-cluster-broker
pvc-568b390e-d8a3-4efa-a528-dbd0934e18e8   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          4m57s
pvc-875bbcc9-5f86-442e-9e05-f2b8852c83ce   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          4m57s
pvc-c328aab2-8948-4791-88df-a488e9fd9faa   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          4m57s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
22513 records sent, 4486.4 records/sec (4.28 MB/sec), 2544.8 ms avg latency, 4258.0 ms max latency.
39104 records sent, 7820.8 records/sec (7.46 MB/sec), 4756.2 ms avg latency, 6197.0 ms max latency.
52928 records sent, 10585.6 records/sec (10.10 MB/sec), 3318.4 ms avg latency, 4669.0 ms max latency.
...
[2024-10-12 12:04:09,916] WARN [Producer clientId=perf-producer-client] Connection to node 7 (my-cluster-broker-7.my-cluster-kafka-brokers.test.svc/10.130.0.31:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-10-12 12:04:09,920] WARN [Producer clientId=perf-producer-client] Connection to node 9 (my-cluster-broker-9.my-cluster-kafka-brokers.test.svc/10.129.0.28:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-10-12 12:04:09,931] WARN [Producer clientId=perf-producer-client] Connection to node 8 (my-cluster-broker-8.my-cluster-kafka-brokers.test.svc/10.131.0.18:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po | grep my-cluster-broker
my-cluster-kafka-7   0/1     CrashLoopBackOff   8 (70s ago)   27m
my-cluster-kafka-8   0/1     CrashLoopBackOff   8 (84s ago)   25m
my-cluster-kafka-9   0/1     CrashLoopBackOff   8 (87s ago)   26m

$ kubectl logs my-cluster-broker-7   | grep "No space left on device" | tail -n1
Caused by: java.io.IOException: No space left on device
```

Even if not all pods failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
If volume expansion is supported on the storage class, you can simply increase the storage size in the Kafka resource, and the operator will take care of it. 
This operation may take some time to complete, depending on the size of the volume and the available resources in the cluster.

> [!WARNING]  
> The expansion is not always feasible in cloud deployments, for example with a standard block size of 4KB an AWS EBS volume can support only up to 16TB.

```sh
[[ $(kubectl get sc $(kubectl get pv | grep data-my-cluster-broker-7 | awk '{print $7}') -o yaml | yq .allowVolumeExpansion) == "true" ]] \
  && kubectl patch knp broker --type merge -p '
    spec:
      storage:
        size: 10Gi'
kafkanodepool.kafka.strimzi.io/broker patched

$ kubectl logs $(kubectl get po | grep cluster-operator | awk '{print $1}') | grep "Resizing"
2024-10-12 12:10:08 INFO  PvcReconciler:137 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-broker-7   from 1 to 10Gi.
2024-10-12 12:10:08 INFO  PvcReconciler:137 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-broker-8   from 1 to 10Gi.
2024-10-12 12:10:08 INFO  PvcReconciler:137 - Reconciliation #1(watch) Kafka(test/my-cluster): Resizing PVC data-my-cluster-broker-9   from 1 to 10Gi.

$ kubectl get po | grep my-cluster-broker
my-cluster-broker-7                           1/1     Running   0          13m
my-cluster-broker-8                           1/1     Running   0          13m
my-cluster-broker-9                           1/1     Running   0          13m

$ kubectl get pv | grep my-cluster-broker
pvc-568b390e-d8a3-4efa-a528-dbd0934e18e8   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          14m
pvc-875bbcc9-5f86-442e-9e05-f2b8852c83ce   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          14m
pvc-c328aab2-8948-4791-88df-a488e9fd9faa   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          14m
```

## Offline Kafka volume recovery with no expansion support (expert level)

> [!WARNING]
> Don't use Minikube, as it uses hostpath volumes that do not enforce storage capacity.

First, [deploy the Strimzi Cluster Operator](/sessions/001).
For the sake of this example, we deploy the Kafka cluster reducing the volume size.

```sh
$ cat sessions/001/install/001-broker-pool.yaml \
    | yq ".spec.storage.size = \"1Gi\"" | kubectl create -f - \
  && kubectl create -f sessions/001/install 2>/dev/null
kafkanodepool.kafka.strimzi.io/broker created
kafkanodepool.kafka.strimzi.io/controller created
kafka.kafka.strimzi.io/my-cluster created
kafkatopic.kafka.strimzi.io/my-topic created

$ kubectl wait --timeout=120s --for=condition=ready k my-cluster; \
  KAFKA_PODS="$(kubectl get po | grep my-cluster-broker | awk '{print $1}')" \
  VOLUME_CLASS="$(kubectl get pv | grep my-cluster-broker | head -n1 | awk '{print $7}')" \
  CLUSTER_ID="$(kubectl get k my-cluster -o yaml | yq .status.clusterId)"
  NEW_VOLUME_SIZE="10Gi"
  
$ kubectl get pv | grep my-cluster-broker
pvc-6efa4986-a8f8-42d3-ae80-0229d262cf81   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          66s
pvc-d76d68c6-52e9-4a9f-a20f-3b052ea49c55   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          66s
pvc-fe5ccdb3-b550-467e-b6e0-f4d3ece79ed0   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          66s
```

When the cluster is ready, we break it by sending 3.3 GiB of data to a topic, which exceeds the cluster capacity.

```sh
$ kubectl-kafka bin/kafka-producer-perf-test.sh --topic my-topic --record-size 1000 --num-records 3300000 \
  --throughput -1 --producer-props acks=all bootstrap.servers=my-cluster-kafka-bootstrap:9092
15521 records sent, 3104.2 records/sec (2.96 MB/sec), 2627.4 ms avg latency, 4363.0 ms max latency.
36192 records sent, 7222.5 records/sec (6.89 MB/sec), 5360.9 ms avg latency, 6964.0 ms max latency.
43728 records sent, 8745.6 records/sec (8.34 MB/sec), 4132.9 ms avg latency, 5104.0 ms max latency.
...
[2024-10-16 16:06:47,718] WARN [Producer clientId=perf-producer-client] Connection to node 7 (my-cluster-broker-7.my-cluster-kafka-brokers.test.svc/10.130.0.17:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-10-16 16:06:47,718] WARN [Producer clientId=perf-producer-client] Connection to node 9 (my-cluster-broker-9.my-cluster-kafka-brokers.test.svc/10.131.0.24:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
[2024-10-16 16:06:47,718] WARN [Producer clientId=perf-producer-client] Connection to node 8 (my-cluster-broker-8.my-cluster-kafka-brokers.test.svc/10.129.0.14:9092) could not be established. Node may not be available. (org.apache.kafka.clients.NetworkClient)
^C

$ kubectl get po | grep my-cluster-broker
my-cluster-broker-7                           0/1     CrashLoopBackOff   2 (12s ago)   3m41s
my-cluster-broker-8                           0/1     CrashLoopBackOff   2 (11s ago)   3m41s
my-cluster-broker-9                           0/1     CrashLoopBackOff   2 (14s ago)   3m41s

$ kubectl logs $(kubectl get po | grep my-cluster-broker | head -n1 | awk '{print $1}') | grep "No space left on device" | tail -n1
Caused by: java.io.IOException: No space left on device
```

Even if not all pods are failed, we still need to increase the volume size of all brokers because the storage configuration is shared.
This procedure works offline because copying data while they are being modified can cause tricky problems, especially if transactions are enabled.

> [!WARNING]  
> Before deleting the Kafka cluster, make sure that delete claim storage configuration is set to false in Kafka resource.

```sh
$ [[ $(kubectl get knp broker -o yaml | yq .spec.storage.deleteClaim) == "false" ]] \
  && kubectl delete knp broker controller && kubectl delete k my-cluster
kafkanodepool.kafka.strimzi.io "controller" deleted
kafkanodepool.kafka.strimzi.io "broker" deleted
kafka.kafka.strimzi.io "my-cluster" deleted
```

Create new and bigger volumes for our brokers.
In this case, volumes are created automatically, but you may need to create them manually.
They will be bound only when the first consumer (pod) will be created.

```sh
$ for pod in $KAFKA_PODS; do
echo "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-$pod-new
  labels:
    strimzi.io/name: my-cluster-kafka
    strimzi.io/pool-name: broker
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $VOLUME_CLASS
  resources:
    requests:
      storage: $NEW_VOLUME_SIZE" | kubectl create -f- 
done
persistentvolumeclaim/data-my-cluster-broker-7-new created
persistentvolumeclaim/data-my-cluster-broker-8-new created
persistentvolumeclaim/data-my-cluster-broker-9-new created

$ kubectl get pvc | grep my-cluster-broker
data-my-cluster-broker-7       Bound     pvc-fe5ccdb3-b550-467e-b6e0-f4d3ece79ed0   1Gi        RWO            gp3-csi        <unset>                 8m25s
data-my-cluster-broker-7-new   Pending                                                                        gp3-csi        <unset>                 15s
data-my-cluster-broker-8       Bound     pvc-d76d68c6-52e9-4a9f-a20f-3b052ea49c55   1Gi        RWO            gp3-csi        <unset>                 8m25s
data-my-cluster-broker-8-new   Pending                                                                        gp3-csi        <unset>                 15s
data-my-cluster-broker-9       Bound     pvc-6efa4986-a8f8-42d3-ae80-0229d262cf81   1Gi        RWO            gp3-csi        <unset>                 8m25s
data-my-cluster-broker-9-new   Pending                                                                        gp3-csi        <unset>                 14s
```

Using a maintenance pod, copy all broker data from the old volumes to the new volumes.

> [!NOTE]  
> The following command may take some time, depending on the amount of data to copy.

```sh
$ for pod in $KAFKA_PODS; do
  kubectl run kubectl-patch-$pod -itq --rm --restart "Never" --image "foo" --overrides "{
  \"spec\": {
    \"containers\": [
      {
        \"name\": \"busybox\",
        \"image\": \"busybox\",
        \"imagePullPolicy\": \"IfNotPresent\",
        \"command\": [\"/bin/sh\", \"-c\", \"cp -auvR /old/* /new\"],
        \"volumeMounts\": [
          {\"name\": \"old\", \"mountPath\": \"/old\"},
          {\"name\": \"new\", \"mountPath\": \"/new\"}
        ]
      }
    ],
    \"volumes\": [
      {\"name\": \"old\", \"persistentVolumeClaim\": {\"claimName\": \"data-$pod\"}},
      {\"name\": \"new\", \"persistentVolumeClaim\": {\"claimName\": \"data-$pod-new\"}}
    ]
  }
}"
done
'/old/kafka-log7/.lock' -> '/new/kafka-log7/.lock'
'/old/kafka-log7/bootstrap.checkpoint' -> '/new/kafka-log7/bootstrap.checkpoint'
'/old/kafka-log7/recovery-point-offset-checkpoint' -> '/new/kafka-log7/recovery-point-offset-checkpoint'
'/old/kafka-log7/meta.properties' -> '/new/kafka-log7/meta.properties'
'/old/kafka-log7/__cluster_metadata-0/00000000000000000256.snapshot' -> '/new/kafka-log7/__cluster_metadata-0/00000000000000000256.snapshot'
'/old/kafka-log7/__cluster_metadata-0/partition.metadata' -> '/new/kafka-log7/__cluster_metadata-0/partition.metadata'
'/old/kafka-log7/__cluster_metadata-0/00000000000000000000.log' -> '/new/kafka-log7/__cluster_metadata-0/00000000000000000000.log'
'/old/kafka-log7/__cluster_metadata-0/00000000000000000000.index' -> '/new/kafka-log7/__cluster_metadata-0/00000000000000000000.index'
'/old/kafka-log7/__cluster_metadata-0/00000000000000000000.timeindex' -> '/new/kafka-log7/__cluster_metadata-0/00000000000000000000.timeindex'
'/old/kafka-log7/__cluster_metadata-0/leader-epoch-checkpoint.tmp' -> '/new/kafka-log7/__cluster_metadata-0/leader-epoch-checkpoint.tmp'
'/old/kafka-log7/__cluster_metadata-0/leader-epoch-checkpoint' -> '/new/kafka-log7/__cluster_metadata-0/leader-epoch-checkpoint'
...

$ kubectl get pv | grep my-cluster-broker
pvc-327097ee-094b-4725-afb9-1077b42f8504   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-8-new   gp3-csi        <unset>                          106s
pvc-5f306a61-0d84-4cbb-b1b4-8e05728f0397   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-7-new   gp3-csi        <unset>                          2m6s
pvc-6efa4986-a8f8-42d3-ae80-0229d262cf81   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          24m
pvc-777daab8-91e0-4560-8c12-e22318ffd9df   10Gi       RWO            Delete           Bound    test/data-my-cluster-broker-9-new   gp3-csi        <unset>                          84s
pvc-d76d68c6-52e9-4a9f-a20f-3b052ea49c55   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          24m
pvc-fe5ccdb3-b550-467e-b6e0-f4d3ece79ed0   1Gi        RWO            Delete           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          24m
```

> [!WARNING]  
> Set the persistent volume reclaim policy as Retain to avoid losing data when deleting broker PVCs.

```sh
$ for pv in $(kubectl get pv | grep my-cluster-broker | awk '{print $1}'); do
  kubectl patch pv $pv --type merge -p '
    spec:
      persistentVolumeReclaimPolicy: Retain'
done
persistentvolume/pvc-6efa4986-a8f8-42d3-ae80-0229d262cf81 patched
persistentvolume/pvc-d76d68c6-52e9-4a9f-a20f-3b052ea49c55 patched
persistentvolume/pvc-fe5ccdb3-b550-467e-b6e0-f4d3ece79ed0 patched
persistentvolume/pvc-777daab8-91e0-4560-8c12-e22318ffd9df patched
persistentvolume/pvc-327097ee-094b-4725-afb9-1077b42f8504 patched
persistentvolume/pvc-5f306a61-0d84-4cbb-b1b4-8e05728f0397 patched

$ kubectl get pv | grep my-cluster-broker
pvc-13e660ba-6a21-4bad-876b-cabab93ce38b   1Gi        RWO            Retain           Bound    test/data-my-cluster-broker-8       gp3-csi        <unset>                          14m
pvc-2522a5ad-5275-4459-83f0-149d8cd007f3   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-8-new   gp3-csi        <unset>                          79s
pvc-26590b0f-c1ba-4069-9c24-f731287a7ed3   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-7-new   gp3-csi        <unset>                          100s
pvc-35fed9c0-f12f-4012-899a-759add4cef4e   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-9-new   gp3-csi        <unset>                          57s
pvc-aed21c6a-3b78-4a18-8e44-596285652b9d   1Gi        RWO            Retain           Bound    test/data-my-cluster-broker-7       gp3-csi        <unset>                          14m
pvc-d7b08cd6-8199-4cbf-9193-98f0f6a3a29d   1Gi        RWO            Retain           Bound    test/data-my-cluster-broker-9       gp3-csi        <unset>                          14m
```

Now, delete all Kafka PVCs and PV claim references, just before creating the new PVCs with the new storage size.
We have to use the same resource name that the operator expects, so that the new volumes will be bound on cluster startup.

```sh
$ for pod in $KAFKA_PODS; do
PVC_NAMES="$(kubectl get pvc | grep data-$pod | awk '{print $1}')"
PV_NAMES="$(kubectl get pv | grep data-$pod | awk '{print $1}')"
NEW_PV_NAME="$(kubectl get pv | grep data-$pod-new | awk '{print $1}')"
kubectl delete pvc $PVC_NAMES
kubectl patch pv $PV_NAMES --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
echo "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-$pod
  labels:
    strimzi.io/name: my-cluster-kafka
    strimzi.io/pool-name: broker
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $VOLUME_CLASS
  volumeName: $NEW_PV_NAME
  resources:
    requests:
      storage: $NEW_VOLUME_SIZE" | kubectl create -f -    
done
persistentvolumeclaim "data-my-cluster-broker-7" deleted
persistentvolumeclaim "data-my-cluster-broker-7-new" deleted
persistentvolume/pvc-26590b0f-c1ba-4069-9c24-f731287a7ed3 patched
persistentvolume/pvc-aed21c6a-3b78-4a18-8e44-596285652b9d patched
persistentvolumeclaim/data-my-cluster-broker-7 created
persistentvolumeclaim "data-my-cluster-broker-8" deleted
persistentvolumeclaim "data-my-cluster-broker-8-new" deleted
persistentvolume/pvc-13e660ba-6a21-4bad-876b-cabab93ce38b patched
persistentvolume/pvc-2522a5ad-5275-4459-83f0-149d8cd007f3 patched
persistentvolumeclaim/data-my-cluster-broker-8 created
persistentvolumeclaim "data-my-cluster-broker-9" deleted
persistentvolumeclaim "data-my-cluster-broker-9-new" deleted
persistentvolume/pvc-35fed9c0-f12f-4012-899a-759add4cef4e patched
persistentvolume/pvc-d7b08cd6-8199-4cbf-9193-98f0f6a3a29d patched
persistentvolumeclaim/data-my-cluster-broker-9 created

$ kubectl get pvc | grep my-cluster-broker
data-my-cluster-broker-7       Bound    pvc-26590b0f-c1ba-4069-9c24-f731287a7ed3   10Gi       RWO            gp3-csi        <unset>                 25s
data-my-cluster-broker-8       Bound    pvc-2522a5ad-5275-4459-83f0-149d8cd007f3   10Gi       RWO            gp3-csi        <unset>                 21s
data-my-cluster-broker-9       Bound    pvc-35fed9c0-f12f-4012-899a-759add4cef4e   10Gi       RWO            gp3-csi        <unset>                 17
```

Deploy the Kafka cluster with our brand new volumes, wait for the cluster to be ready, and try to consume some data.

> [!IMPORTANT]  
> We adjust the storage size in Kafka custom resource, and set the previous `clusterId` in the Kafka CR status.
> To speed up log recovery and partition synchronization, we can also tune recovery threads and replica fetchers.

```sh
$ cat sessions/001/install/001-broker-pool.yaml \
    | yq ".spec.storage.size = \"10Gi\"" | kubectl create -f - \
  && cat sessions/001/install/002-my-cluster.yaml \
    | yq ".metadata.annotations.\"strimzi.io/pause-reconciliation\" = \"true\"" \
    | yq ".spec.kafka.config.\"num.recovery.threads.per.data.dir\" = 5" \
    | yq ".spec.kafka.config.\"num.replica.fetchers\" = 5" | kubectl create -f - \
  && kubectl create -f sessions/001/install 2>/dev/null
kafkanodepool.kafka.strimzi.io/broker created
kafka.kafka.strimzi.io/my-cluster created
kafkanodepool.kafka.strimzi.io/controller created

$ kubectl patch k my-cluster --subresource status --type merge -p "
  status:
    clusterId: \"$CLUSTER_ID\""
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl annotate k my-cluster strimzi.io/pause-reconciliation=false --overwrite
kafka.kafka.strimzi.io/my-cluster annotated

$ kubectl get po | grep my-cluster-broker
my-cluster-broker-7                           1/1     Running   0          4m34s
my-cluster-broker-8                           1/1     Running   0          4m34s
my-cluster-broker-9                           1/1     Running   0          4m33s

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning --max-messages 3
XVFTWDJKAIYRBIKZRFOEZNWURGQHGPDMOZYAEBTFLNCXMVOJOCPCXZLUZJKPTIFQVRHWKHBMTMHFHJGAIXNWURPJOKMXRAWLHMUNNWVYSNPIMZXJDKSLVMLJYZFJCQOIQXNFLYYYTEFK...
FVABXPFDUNYNYMNVYWZDVZLGZASDYATOWNFMRODUPWCUVVIZFRLZNDOSQWZVNGMGEYHDVAWZDQLXBAIZGFDUOKGGHDBTLOJLMLPXTPXXZZQXFIVTAZOHHGWJBUSMPKIPCMOAJVSLUYGJ...
OAPJJFCTIWBLZMWUVMWRSGJQMXVLATYRECKCHDEIHYOMLCLKAULDWNSRIXKVWSNHLJUADUZNUMCJQYASBCSJWHIKXLATGMGNENPSSVIUAWSRRABUBXFZZRKOGOFGTBVIWTWFUWHEEMGF...
Processed a total of 3 messages
```

Finally, we delete the old volumes to reclaim some space.

```sh
$ kubectl delete pv $(kubectl get pv | grep Available | awk '{print $1}')
persistentvolume "pvc-2522a5ad-5275-4459-83f0-149d8cd007f3" deleted
persistentvolume "pvc-26590b0f-c1ba-4069-9c24-f731287a7ed3" deleted
persistentvolume "pvc-35fed9c0-f12f-4012-899a-759add4cef4e" deleted

$ kubectl get pv | grep my-cluster-broker
pvc-2522a5ad-5275-4459-83f0-149d8cd007f3   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-8-new   gp3-csi        <unset>                          79s
pvc-26590b0f-c1ba-4069-9c24-f731287a7ed3   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-7-new   gp3-csi        <unset>                          100s
pvc-35fed9c0-f12f-4012-899a-759add4cef4e   10Gi       RWO            Retain           Bound    test/data-my-cluster-broker-9-new   gp3-csi        <unset>                          57s
```
