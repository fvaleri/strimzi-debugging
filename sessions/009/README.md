## Diagnostic data collection

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

This example shows how to collect broker JVM heap dumps, but it works similarly for other types of diagnostic data (thread dumps, flame graphs, etc).

> [!WARNING]
> Taking a heap dump is a heavy operation that can cause the Java application to hang.
> It is not recommended in production, unless it is not possible to reproduce the memory issue in a test environment.

Debugging locally can often be easier and faster.
However, some issues only manifest in Kubernetes due to factors like networking, resource limits, or interactions with other components.
Even if you try to match your local setup to the Kubernetes configuration, subtle differences (e.g. service discovery, security settings, or operator-managed logic) might lead to different behavior.

When the Kafka cluster is ready, create an additional volume of the desired size using a PVC.

```sh
$ echo -e "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard" | kubectl create -f -
persistentvolumeclaim/my-pvc created
```

Mount the new volume using the additional volume feature within Kafka template (rolling update).
It is required to use `/mnt` mount point.

> [!WARNING]
> Adding a custom volume triggers pod restarts, which can make it difficult to capture an issue that has already occurred.
> If the issue cannot be easily reproduced in a test environment, configuring the volume in advance could help avoid the pod restarts when you need them most.

```sh
$ kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        template:
            pod:
              volumes:
                - name: my-volume
                  persistentVolumeClaim:
                    claimName: my-pvc
            kafkaContainer:
              volumeMounts:
                - name: my-volume
                  mountPath: "/mnt/data"'
kafka.kafka.strimzi.io/my-cluster patched
```

When the rolling update completes, create a broker heap dump and copy the output file to localhost.

```sh
$ PID="$(kubectl exec my-cluster-broker-5 -- jcmd | grep "kafka.Kafka" | awk '{print $1}')"

$ kubectl exec my-cluster-broker-5 -- jcmd "$PID" VM.flags
724:
-XX:CICompilerCount=4 -XX:ConcGCThreads=3 -XX:G1ConcRefinementThreads=10 -XX:G1EagerReclaimRemSetThreshold=32 -XX:G1HeapRegionSize=4194304
-XX:GCDrainStackTargetSize=64 -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/mnt/data/oome.hprof -XX:InitialHeapSize=5368709120
-XX:+ManagementServer -XX:MarkStackSize=4194304 -XX:MaxHeapSize=5368709120 -XX:MaxNewSize=3221225472 -XX:MinHeapDeltaBytes=4194304
-XX:MinHeapSize=5368709120 -XX:NonNMethodCodeHeapSize=5839372 -XX:NonProfiledCodeHeapSize=122909434 -XX:ProfiledCodeHeapSize=122909434
-XX:ReservedCodeCacheSize=251658240 -XX:+SegmentedCodeCache -XX:SoftMaxHeapSize=5368709120 -XX:-THPStackMitigation
-XX:+UseCompressedClassPointers -XX:+UseCompressedOops -XX:+UseFastUnorderedTimeStamps -XX:+UseG1GC

$ kubectl exec my-cluster-broker-5 -- jcmd "$PID" GC.heap_dump /mnt/data/heap.hprof
724:
Dumping heap to /mnt/data/heap.hprof ...
Heap dump file created [179236580 bytes in 0.664 secs]

$ kubectl cp my-cluster-broker-5:/mnt/data/heap.hprof "$HOME"/Downloads/heap.hprof
tar: Removing leading `/' from member names
```

If the pod is crash looping, the dump can still be recovered by spinning up a temporary pod and mounting the volume.

```sh
$ kubectl run my-pod --restart "Never" --image "foo" --overrides "{
  \"spec\": {
    \"containers\": [
      {
        \"name\": \"busybox\",
        \"image\": \"busybox\",
        \"imagePullPolicy\": \"IfNotPresent\",
        \"command\": [\"/bin/sh\", \"-c\", \"trap : TERM INT; sleep infinity & wait\"],
        \"volumeMounts\": [
          {\"name\": \"data\", \"mountPath\": \"/mnt/data\"}
        ]
      }
    ],
    \"volumes\": [
      {\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"my-pvc\"}}
    ]
  }
}"

$ kubectl exec my-pod -- ls -lh /mnt/data
total 171M   
-rw-------    1 1001     root      170.9M Mar 17 14:38 heap.hprof
```

For the heap dump analysis you can use a tool like Eclipse Memory Analyzer.
