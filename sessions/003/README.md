## Schema registry in action

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.
We also add an external listener (see [session2](/sessions/002) for more details).

```sh
$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      listeners:
        - name: external
          port: 9094
          type: ingress
          tls: true
          configuration:
            bootstrap:
              host: kafka-bootstrap.my-cluster.local
            brokers:
              - broker: 7
                host: kafka-7.my-cluster.local
              - broker: 8
                host: kafka-8.my-cluster.local
              - broker: 9
                host: kafka-9.my-cluster.local
            class: nginx'
kafka.kafka.strimzi.io/my-cluster patched
```

Then, we deploy the Service Registry instance with the in-memory storage system.

```sh
$ for f in sessions/003/install/*.yaml; do sed "s/namespace: .*/namespace: $NAMESPACE/g" $f \
  | kubectl create -f - --dry-run=client -o yaml | kubectl replace --force -f -; done
customresourcedefinition.apiextensions.k8s.io/apicurioregistries.registry.apicur.io replaced
serviceaccount/apicurio-registry-operator replaced
role.rbac.authorization.k8s.io/apicurio-registry-operator-leader-election-role replaced
clusterrole.rbac.authorization.k8s.io/apicurio-registry-operator-role replaced
rolebinding.rbac.authorization.k8s.io/apicurio-registry-operator-leader-election-rolebinding replaced
clusterrolebinding.rbac.authorization.k8s.io/apicurio-registry-operator-rolebinding replaced
deployment.apps/apicurio-registry-operator replaced
apicurioregistry.registry.apicur.io/my-registry replaced

$ kubectl get po
NAME                                          READY   STATUS    RESTARTS   AGE
apicurio-registry-operator-9448ffc74-n699g    1/1     Running   0          99s
my-cluster-broker-7                           1/1     Running   0          95s
my-cluster-broker-8                           1/1     Running   0          67s
my-cluster-broker-9                           1/1     Running   0          42s
my-cluster-controller-0                       1/1     Running   0          3m53s
my-cluster-controller-1                       1/1     Running   0          3m53s
my-cluster-controller-2                       1/1     Running   0          3m53s
my-cluster-entity-operator-867cbbf79c-6b7mk   2/2     Running   0          3m20s
my-registry-deployment-858c7dc76b-xq7bt       1/1     Running   0          96s
strimzi-cluster-operator-7fb8ff4bd-2wbmb      1/1     Running   0          4m18s
```

Now, we just need to tell our client application where it can find the Kafka cluster by setting the bootstrap URL and the schema registry REST endpoint.
We also need to provide the truststore location and password because we are connecting externally.

```sh
$ kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.p12']}" | base64 -d >/tmp/truststore.p12 \
  && export BOOTSTRAP_SERVERS=$(kubectl get k my-cluster -o yaml | yq '.status.listeners.[] | select(.name == "external").bootstrapServers') \
  REGISTRY_URL=http://$(kubectl get apicurioregistries my-registry -o jsonpath="{.status.info.host}")/apis/registry/v2 \
  KAFKA_VERSION TOPIC_NAME="my-topic" ARTIFACT_GROUP="default" SSL_TRUSTSTORE_LOCATION="/tmp/truststore.p12" \
  SSL_TRUSTSTORE_PASSWORD=$(kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.password']}" | base64 -d)

$ mvn clean compile exec:java -f sessions/003/kafka-avro/pom.xml -q
Producing records
Records produced
Consuming all records
Record: Hello-1663594981476
Record: Hello-1663594982041
Record: Hello-1663594982041
Record: Hello-1663594982041
Record: Hello-1663594982042
```

[Look at the code](/sessions/003/kafka-avro/src/main/java/it/fvaleri/example/Main.java) to see how the schema is registered and used.
The registration happens at build time and the Maven plugin executes the following API request for every configured schema artifact.

> [!NOTE]  
> We are using the `default` group id, but you can specify a custom name.

```sh
$ curl -s -X POST -H "Content-Type: application/json" \
  -H "X-Registry-ArtifactId: my-topic-value" -H "X-Registry-ArtifactType: AVRO" \
  -d @sessions/003/kafka-avro/src/main/resources/greeting.avsc \
  "$REGISTRY_URL/groups/default/artifacts?ifExists=RETURN_OR_UPDATE" | jq
{
  "name": "Greeting",
  "createdBy": "",
  "createdOn": "2022-09-30T06:31:36+0000",
  "modifiedBy": "",
  "modifiedOn": "2022-09-30T06:31:36+0000",
  "id": "my-topic-value",
  "version": "1",
  "type": "AVRO",
  "globalId": 4,
  "state": "ENABLED",
  "contentId": 6
}
```

Finally, we use the REST API to confirm that our schema was registered correctly.
We can also look at the schema content and metadata, which may be useful for debugging.

```sh
$ curl -s "$REGISTRY_URL/search/artifacts" | jq
{
  "artifacts": [
    {
      "id": "my-topic-value",
      "name": "Greeting",
      "createdOn": "2022-09-19T13:42:59+0000",
      "createdBy": "",
      "type": "AVRO",
      "state": "ENABLED",
      "modifiedOn": "2022-09-19T13:42:59+0000",
      "modifiedBy": ""
    }
  ],
  "count": 1
}

$ curl -s "$REGISTRY_URL/groups/default/artifacts/my-topic-value" | jq
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

$ curl -s "$REGISTRY_URL/groups/default/artifacts/my-topic-value/meta" | jq
{
  "name": "Greeting",
  "createdBy": "",
  "createdOn": "2022-09-19T13:42:59+0000",
  "modifiedBy": "",
  "modifiedOn": "2022-09-19T13:42:59+0000",
  "id": "my-topic-value",
  "version": "1",
  "type": "AVRO",
  "globalId": 1,
  "state": "ENABLED",
  "contentId": 1
}
```
