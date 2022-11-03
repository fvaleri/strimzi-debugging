## Kafka Connect and change data capture

Kafka Connect is a configuration-driven fault-tolerant integration platform based on Kafka client APIs, which runs in standalone or distributed mode (cluster of workers).
The platform can be extended by using connector, converter and transformation plugins which implement the connect API interfaces.
The recommended way to add them is by using the `plugin.path` property, that provides some level of isolation.

There are two kinds of connectors: source connector, for importing data from an external system to Kafka, and sink connector, for exporting data from Kafka to an external system.
Only few connectors are officially part of Kafka, but there are many available on GitHub or on public registries like Confluent Hub.

The converters are used by connectors to serialize and deserialize data when talking to the Kafka cluster, while transformations, also called single message transformations (SMTs), can be used to apply lightweight changes at the record level (filters, mappings, replacements).
When you need to do heavy transformations (e.g. aggregations, joins, call external services), you should use a stream processing library like Kafka Streams.

![](images/connect.png)

Each connector job is split into a number of single thread tasks which run on worker nodes.
You can configure the max number of created tasks by setting the `maxTasks` at the connector configuration level, but the actual number of tasks depends on the specific connector and, for sink connectors, on how many input partitions we have.

Tasks rebalancing happens when a worker fails, a new connector is added or there is a configuration change, but not when a task fails.
Configurations and other metadata are stored inside internal Kafka topics so that they can be easily recovered in case of worker crash.

- `offset.storage.topic`: The name of the compacted topic where source connector offsets are stored.
  Sink connectors store the offset inside `__consumer_offsets` like normal consumer groups.
- `config.storage.topic`: The name of the compacted topic where connector configurations are stored.
- `status.storage.topic`: The name of the compacted topic where connector and task states are stored.

The change data capture (CDC) pattern describes a system that captures and emit data changes, so that other applications can respond to those events.
[Debezium](https://debezium.io) is a CDC engine that works best when deployed on top of Kafka Connect.
It is actually a collection of source connectors, that can be used to create data pipelines to bridge traditional data stores with Kafka.

The connector produces change events by performing an initial snapshot and then reads the internal transaction log from the point at which the snapshot was made.
There is also the possibility to configure incremental snapshots.
The main disadvantage of using Debezium is that every connector requires a specific configuration to enable access to the transaction log.
If you are fine with that, the advantages over a poll-based connector or application are significant:

- Low overhead: near real-time reaction to data changes avoids increased CPU load due to frequent polling.
- No lost changes: using a poll loop you may miss intermediary changes between two runs (updates, deletes).
- No data model impact: no need for timestamp columns to determine the last update of data.

Debezium change events are self contained because each message includes the JSON Schema, so that we can always consume them even if the data source schema changes over time.
In case of Kafka or external system failure, Debezium connector will reconnect and resume once they are restored.
If the connector stops for too long and the transaction log is purged, then the connector lose its position and performs another initial snapshot.
By default, Debezium provides at-least-once semantics, which means duplicates can arise in failure scenarios.
The change event contains elements that can be used to identify and filter out duplicates.

### Example: cloud-native CDC pipeline

[Deploy Streams operator and Kafka cluster](/sessions/001).
When the cluster is ready, we can deploy MySQL instance (the external system) and Kafka Connect cluster.
Note that we are also initializing the database.
The Kafka Connect image uses an internal component (kaniko) to build a custom image containing the configured MySQL connector.
This component requires credentials for pushing to an external image registry, so we first need to create a secret for that (pro tip: you can use a quay.io robot account instead of your user account).

```sh
# use your credentials
$ kubectl create secret docker-registry registry-authn \
  --docker-server="quay.io" --docker-username="fvaleri+r2d2" --docker-password="changeit" \
  --dry-run=client -o yaml | kubectl replace --force -f -
secret/registry-authn replaced

# use your image name
$ for file in sessions/004/crs/*.yaml; do sed "s#value0#quay.io/fvaleri/my-connect:latest#g" $file | kubectl create -f -; done \
  && kubectl wait --for="condition=Ready" pod -l app=mysql --timeout=300s \
  && kubectl exec my-mysql-ss-0 -- bash -c 'mysql -u root < /tmp/sql/initdb.sql'
persistentvolumeclaim/my-mysql-data created
configmap/my-mysql-cfg created
configmap/my-mysql-env created
configmap/my-mysql-init created
statefulset.apps/my-mysql-ss created
service/my-mysql-svc created
kafkaconnect.kafka.strimzi.io/my-connect created
kafkaconnector.kafka.strimzi.io/mysql-source created
pod/my-mysql-ss-0 condition met

$ kubectl get po,kt
NAME                                              READY   STATUS      RESTARTS   AGE
pod/my-cluster-entity-operator-6b68959588-8mccx   3/3     Running     0          30m
pod/my-cluster-kafka-0                            1/1     Running     0          32m
pod/my-cluster-kafka-1                            1/1     Running     0          32m
pod/my-cluster-kafka-2                            1/1     Running     0          32m
pod/my-cluster-zookeeper-0                        1/1     Running     0          34m
pod/my-cluster-zookeeper-1                        1/1     Running     0          34m
pod/my-cluster-zookeeper-2                        1/1     Running     0          34m
pod/my-connect-connect-95d5c7478-2vkwt            1/1     Running     0          10m
pod/my-connect-connect-build-1-build              0/1     Completed   0          11m
pod/my-mysql-ss-0                                 1/1     Running     0          11m

NAME                                                                                                                           CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/connect-cluster-configs                                                                            my-cluster   1            3                    True
kafkatopic.kafka.strimzi.io/connect-cluster-offsets                                                                            my-cluster   25           3                    True
kafkatopic.kafka.strimzi.io/connect-cluster-status                                                                             my-cluster   5            3                    True
kafkatopic.kafka.strimzi.io/consumer-offsets---84e7a678d08f4bd226872e5cdd4eb527fadc1c6a                                        my-cluster   50           3                    True
kafkatopic.kafka.strimzi.io/debezium-heartbeat.my-mysql---76187ecaffdb5bfe72afa38b976011f2e16fa30b                             my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/my-mysql                                                                                           my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/my-topic                                                                                           my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/strimzi-store-topic---effb8e3e057afce1ecf67c3f5d8e4e3ff177fc55                                     my-cluster   1            3                    True
kafkatopic.kafka.strimzi.io/strimzi-topic-operator-kstreams-topic-store-changelog---b75e702040b99be8a9263134de3507fc0cc4017b   my-cluster   1            3                    True
kafkatopic.kafka.strimzi.io/testdb.history                                                                                     my-cluster   1            3                    True
```

As you may have guessed at this point, we are going to emit MySQL row changes and import them into Kafka, so that other applications can pick them up and process.
Let's check if the connector and its tasks are running fine by using the `KafkaConnector` resource, which is easier than interacting via REST requests.

```sh
$ kubectl get kctr mysql-source -o yaml | yq '.status'
conditions:
  - lastTransitionTime: "2022-09-15T07:56:48.585862Z"
    status: "True"
    type: Ready
connectorStatus:
  connector:
    state: RUNNING
    worker_id: 10.128.2.29:8083
  name: mysql-source
  tasks:
    - id: 0
      state: RUNNING
      worker_id: 10.128.2.29:8083
  type: source
observedGeneration: 1
tasksMax: 1
topics:
  - __debezium-heartbeat.my-mysql
  - my-mysql
```

Debezium configuration is specific to each connector and it is documented in details.
The value of `server_id` must be unique for each server and replication client in MySQL cluster.
In this case, MySQL user must have appropriate permissions on all databases for which the connector captures changes.

```sh
$ kubectl get cm my-mysql-cfg -o yaml | yq '.data'
my.cnf: |
  !include /etc/my.cnf
  [mysqld]
  server_id = 224466
  log_bin = mysql-bin
  binlog_format = ROW
  binlog_row_image = FULL
  binlog_rows_query_log_events = ON
  expire_logs_days = 10
  gtid_mode = ON
  enforce_gtid_consistency = ON

$ kubectl get cm my-mysql-init -o yaml | yq '.data'
initdb.sql: |
  use testdb;
    CREATE TABLE customers (
    id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(255) NOT NULL,
    last_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE
  );

  CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED WITH caching_sha2_password BY 'changeit';
  GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
  FLUSH PRIVILEGES;

$ kubectl get kc my-connect -o yaml | yq '.spec.build.plugins'
- artifacts:
    - type: zip
      url: https://maven.repository.redhat.com/ga/io/debezium/debezium-connector-mysql/1.9.5.Final-redhat-00001/debezium-connector-mysql-1.9.5.Final-redhat-00001-plugin.zip
  name: debezium-mysql

$ kubectl get kctr mysql-source -o yaml | yq '.spec'
class: io.debezium.connector.mysql.MySqlConnector
config:
  database.allowPublicKeyRetrieval: true
  database.dbname: testdb
  database.history.kafka.bootstrap.servers: my-cluster-kafka-bootstrap:9092
  database.history.kafka.topic: testdb.history
  database.hostname: my-mysql-svc
  database.include.list: testdb
  database.password: changeit
  database.port: 3306
  database.server.id: "222222"
  database.server.name: my-mysql
  database.user: debezium
  heartbeat.interval.ms: 10000
  snapshot.mode: when_needed
  table.include.list: testdb.customers
tasksMax: 1
```

Enough with describing the configuration, now let's create some changes using the good old SQL.

```sh
$ kubectl exec my-mysql-ss-0 -- sh -c 'MYSQL_PWD="changeit" mysql -u admin testdb -e "
  INSERT INTO customers (first_name, last_name, email) VALUES (\"John\", \"Doe\", \"jdoe@example.com\");
  UPDATE customers SET first_name = \"Jane\" WHERE id = 1;
  INSERT INTO customers (first_name, last_name, email) VALUES (\"Dylan\", \"Dog\", \"ddog@example.com\");
  SELECT * FROM customers;"'
id	first_name	last_name	email
1	Jane	Doe	jdoe@example.com
2	Dylan	Dog	ddog@example.com
```

The MySQL connector writes change events that occur in a table to a Kafka topic named like `serverName.databaseName.tableName`.
We created 3 changes (insert-update-insert), so we have 3 records in that topic.
It's interesting to look at some record properties: `op` is the change type (c=create, r=read for snapshot only, u=update, d=delete), `gtid` is the global transaction identifiers tha is unique in a MySQL cluster, `payload.source.ts_ms` is the timestamp when the change was applied, `payload.ts_ms` is the timestamp when Debezium processed that event (the notification lag is the difference with the source ts).

```sh
$ krun_kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-mysql.testdb.customers --from-beginning --timeout-ms 5000
Struct{after=Struct{id=2,first_name=Dylan,last_name=Dog,email=ddog@example.com},source=Struct{version=1.9.5.Final-redhat-00001,connector=mysql,name=my-mysql,ts_ms=1663228576000,db=testdb,table=customers,server_id=224466,gtid=1c90a695-34cb-11ed-aba8-0a580a810216:16,file=mysql-bin.000002,pos=2585,row=0,thread=67},op=c,ts_ms=1663228576092}
Struct{after=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},source=Struct{version=1.9.5.Final-redhat-00001,connector=mysql,name=my-mysql,ts_ms=1663228576000,db=testdb,table=customers,server_id=224466,gtid=1c90a695-34cb-11ed-aba8-0a580a810216:14,file=mysql-bin.000002,pos=1690,row=0,thread=67},op=c,ts_ms=1663228576088}
Struct{before=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},after=Struct{id=1,first_name=Jane,last_name=Doe,email=jdoe@example.com},source=Struct{version=1.9.5.Final-redhat-00001,connector=mysql,name=my-mysql,ts_ms=1663228576000,db=testdb,table=customers,server_id=224466,gtid=1c90a695-34cb-11ed-aba8-0a580a810216:15,file=mysql-bin.000002,pos=2103,row=0,thread=67},op=u,ts_ms=1663228576091}
org.apache.kafka.common.errors.TimeoutException
Processed a total of 3 messages
pod "krun-1664982897" deleted
```

As additional exercise, you can extend this data pipeline by configuring some sink connector and export these changes to an external system like AMQ broker.
