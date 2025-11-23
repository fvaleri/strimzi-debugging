## Using Kafka with Apicurio Registry

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Next, deploy the Apicurio Registry operator.

```sh
$ envsubst < sessions/005/install/apicurio.yaml | kubectl create -f -
customresourcedefinition.apiextensions.k8s.io/apicurioregistries.registry.apicur.io created
serviceaccount/apicurio-registry-operator created
role.rbac.authorization.k8s.io/apicurio-registry-operator-leader-election-role created
clusterrole.rbac.authorization.k8s.io/apicurio-registry-operator-role created
rolebinding.rbac.authorization.k8s.io/apicurio-registry-operator-leader-election-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/apicurio-registry-operator-rolebinding created
deployment.apps/apicurio-registry-operator created
```

Once the operator is ready, deploy a registry instance configured with an in-memory storage system.

```sh
$ kubectl create -f sessions/005/install/registry.yaml
apicurioregistry.registry.apicur.io/my-schema-registry created

$ kubectl get po
NAME                                              READY   STATUS    RESTARTS   AGE
apicurio-registry-operator-9448ffc74-b6whl        1/1     Running   0          69s
my-cluster-broker-10                              1/1     Running   0          4m54s
my-cluster-broker-11                              1/1     Running   0          4m27s
my-cluster-broker-12                              1/1     Running   0          5m19s
my-cluster-controller-0                           1/1     Running   0          7m32s
my-cluster-controller-1                           1/1     Running   0          7m32s
my-cluster-controller-2                           1/1     Running   0          7m32s
my-cluster-entity-operator-67b8cc5c87-74qlb       2/2     Running   0          6m59s
my-schema-registry-deployment-858c7dc76b-gjkcs    1/1     Running   0          66s
strimzi-cluster-operator-d78fd875b-dcjxw          1/1     Running   0          8m36s
```

Now export the connection parameters and register the test Avro message schema.

> [!NOTE]
> Besides the REST API, the registry provides a web interface for managing schemas and validation rules.
> Access it using the auto-generated ingress address.

The artifact `id` naming convention combines the topic name with either "key" or "value", depending on whether the serializer handles message keys or values.
The generated `globalId` is stored in message headers and used for schema lookup during consumption.
While different schema `version`s share the same artifact `id`, each has a unique `globalId`.

```sh
$ export BOOTSTRAP_SERVERS=$(kubectl get k my-cluster -o yaml | yq '.status.listeners.[] | select(.name == "plain").bootstrapServers') \
  REGISTRY_URL=http://$(kubectl get apicurioregistries my-schema-registry -o jsonpath="{.status.info.host}")/apis/registry/v2 \
  ARTIFACT_GROUP="default" \
  TOPIC_NAME="my-topic"

$ curl -s -X POST -H "Content-Type: application/json" \
  -H "X-Registry-ArtifactId: my-topic-value" -H "X-Registry-ArtifactType: AVRO" \
  -d @sessions/005/install/greeting.avsc \
  "$REGISTRY_URL"/groups/default/artifacts?ifExists=RETURN_OR_UPDATE | yq -o json
{
  "name": "Greeting",
  "createdBy": "",
  "createdOn": "2025-03-24T07:26:33+0000",
  "modifiedBy": "",
  "modifiedOn": "2025-03-24T07:26:33+0000",
  "id": "my-topic-value",
  "version": "1",
  "type": "AVRO",
  "globalId": 1,
  "state": "ENABLED",
  "contentId": 1,
  "references": []
}
```

With the schema registered, start the application and observe its output.

```sh
$ envsubst < sessions/005/install/kafka-avro.yaml | kubectl create -f -
deployment.apps/kafka-avro created

$ kubectl logs -f $(kubectl get po -l app=kafka-avro -o name)
08:25:25.624 [main] INFO  it.fvaleri.kafka.Main - Producing records
08:25:25.832 [main] INFO  it.fvaleri.kafka.Main - Records produced
08:25:25.832 [main] INFO  it.fvaleri.kafka.Main - Consuming all records
08:25:29.539 [main] INFO  it.fvaleri.kafka.Main - Record: Hello-1758875125640
08:25:29.540 [main] INFO  it.fvaleri.kafka.Main - Record: Hello-1758875125831
08:25:29.540 [main] INFO  it.fvaleri.kafka.Main - Record: Hello-1758875125832
08:25:29.540 [main] INFO  it.fvaleri.kafka.Main - Record: Hello-1758875125832
08:25:29.540 [main] INFO  it.fvaleri.kafka.Main - Record: Hello-1758875125832
```

Inspecting a message reveals that the `globalId` is stored in the message headers, enabling schema lookup during consumption.

```sh
$ kubectl exec my-cluster-broker-10 -- bin/kafka-dump-log.sh --deep-iteration --print-data-log \
  --files /var/lib/kafka/data/kafka-log10/my-topic-0/00000000000000000000.log | tail -n2
| offset: 15 CreateTime: 1742802014915 keySize: -1 valueSize: 12 sequence: 4 headerKeys: [apicurio.value.globalId,apicurio.value.encoding] payload: 
Hello????e
```

Finally, use the REST API to examine schema content and metadata, which can be helpful for debugging purposes.

```sh
$ curl -s "$REGISTRY_URL"/search/artifacts | yq -o json
{
  "artifacts": [
    {
      "id": "my-topic-value",
      "name": "Greeting",
      "createdOn": "2025-03-24T07:26:33+0000",
      "createdBy": "",
      "type": "AVRO",
      "state": "ENABLED",
      "modifiedOn": "2025-03-24T07:26:33+0000",
      "modifiedBy": ""
    }
  ],
  "count": 1
}

$ curl -s "$REGISTRY_URL"/groups/default/artifacts/my-topic-value | yq -o json
{
  "type": "record",
  "name": "Greeting",
  "fields": [
    {
      "name": "Message",
      "type": "string"
    },
    {
      "name": "Time",
      "type": "long"
    }
  ]
}

$ curl -s "$REGISTRY_URL"/groups/default/artifacts/my-topic-value/meta | yq -o json
{
  "name": "Greeting",
  "createdBy": "",
  "createdOn": "2025-03-24T07:26:33+0000",
  "modifiedBy": "",
  "modifiedOn": "2025-03-24T07:26:33+0000",
  "id": "my-topic-value",
  "version": "1",
  "type": "AVRO",
  "globalId": 1,
  "state": "ENABLED",
  "contentId": 1,
  "references": []
}
```
