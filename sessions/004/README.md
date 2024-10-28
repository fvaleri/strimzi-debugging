## Cloud-native CDC pipeline with Debezium

First, use [session1](/sessions/001) to deploy a Kafka cluster on Kubernetes.
When the cluster is ready, we deploy a MySQL instance (the external system), and Kafka Connect cluster.

> [!IMPORTANT]  
> The Kafka Connect image uses an internal component (Kaniko) to build a custom image containing the configured MySQL connector.
> In production, this is not recommended, so you should use your own Connect image built from the Strimzi one.

```sh
$ kubectl create -f sessions/004/install && kubectl wait --for=condition=Ready pod -l app=my-mysql --timeout=300s \
  && kubectl exec my-mysql-0 -- sh -c 'mysql -u root < /tmp/sql/initdb.sql'
persistentvolumeclaim/my-mysql-data created
configmap/my-mysql-cfg created
configmap/my-mysql-env created
configmap/my-mysql-init created
statefulset.apps/my-mysql created
service/my-mysql-svc created
kafkaconnect.kafka.strimzi.io/my-connect-cluster created
kafkaconnector.kafka.strimzi.io/mysql-source-connector created
pod/my-mysql-0 condition met

$ kubectl get po,kt,kctr
NAME                                              READY   STATUS    RESTARTS   AGE
pod/my-cluster-broker-7                           1/1     Running   0          6m1s
pod/my-cluster-broker-8                           1/1     Running   0          6m1s
pod/my-cluster-broker-9                           1/1     Running   0          6m1s
pod/my-cluster-controller-0                       1/1     Running   0          6m1s
pod/my-cluster-controller-1                       1/1     Running   0          6m1s
pod/my-cluster-controller-2                       1/1     Running   0          6m1s
pod/my-cluster-entity-operator-7bc799c449-8jxmb   2/2     Running   0          5m27s
pod/my-connect-cluster-connect-0                  1/1     Running   0          2m46s
pod/my-mysql-0                                    1/1     Running   0          4m19s
pod/strimzi-cluster-operator-d78fd875b-q9sds      1/1     Running   0          6m30s

NAME                                   CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/my-topic   my-cluster   3            3                    True

NAME                                                     CLUSTER              CONNECTOR CLASS                              MAX TASKS   READY
kafkaconnector.kafka.strimzi.io/mysql-source-connector   my-connect-cluster   io.debezium.connector.mysql.MySqlConnector   1           True
```

As you may have guessed at this point, we are going to emit MySQL row changes and import them into Kafka, so that other applications can pick them up and process them.
Let's check if the connector and its tasks are running fine by using the `KafkaConnector` resource, which is easier than interacting via REST requests.

```sh
$ kubectl get kctr mysql-source-connector -o yaml | yq .status
conditions:
  - lastTransitionTime: "2024-10-28T10:53:20.123553787Z"
    status: "True"
    type: Ready
connectorStatus:
  connector:
    state: RUNNING
    worker_id: my-connect-cluster-connect-0.my-connect-cluster-connect.test.svc:8083
  name: mysql-source-connector
  tasks:
    - id: 0
      state: RUNNING
      worker_id: my-connect-cluster-connect-0.my-connect-cluster-connect.test.svc:8083
  type: source
observedGeneration: 1
tasksMax: 1
topics:
  - __debezium-heartbeat.my-mysql
  - my-mysq
```

Debezium configuration is specific to each connector and it is documented in detail.
The value of `server_id` must be unique for each server and replication client in the MySQL cluster.
In this case, the MySQL user must have appropriate permissions on all databases for which the connector captures changes.

```sh
$ kubectl get cm my-mysql-cfg -o yaml | yq .data
my.cnf: |
  !include /etc/my.cnf
  [mysqld]
  server_id = 111111  
  log_bin = mysql-bin
  binlog_format = ROW
  binlog_row_image = FULL
  binlog_rows_query_log_events = ON
  expire_logs_days = 10
  gtid_mode = ON
  enforce_gtid_consistency = ON

$ kubectl get cm my-mysql-init -o yaml | yq .data
initdb.sql: |
  use testdb;
    CREATE TABLE IF NOT EXISTS customers (
    id INTEGER NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(255) NOT NULL,
    last_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE
  );

  CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED WITH caching_sha2_password BY 'changeit';
  GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
  FLUSH PRIVILEGES;
```

Enough with describing the configuration, now let's create some changes using good old SQL.

```sh
$ kubectl exec my-mysql-0 -- sh -c 'MYSQL_PWD="changeit" mysql -u admin testdb -e "
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
It's interesting to look at some record properties: `op` is the change type (c=create, r=read for snapshot only, u=update, d=delete), `gtid` is the global transaction identifier that is unique in a MySQL cluster, `payload.source.ts_ms` is the timestamp when the change was applied, `payload.ts_ms` is the timestamp when Debezium processed that event. The notification lag is the difference with the source timestamp.

```sh
$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-mysql.testdb.customers --from-beginning --max-messages 3
Struct{after=Struct{id=2,first_name=Dylan,last_name=Dog,email=ddog@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:16,file=mysql-bin.000002,pos=2602,row=0,thread=61},op=c,ts_ms=1730112871209}
Struct{after=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:14,file=mysql-bin.000002,pos=1707,row=0,thread=61},op=c,ts_ms=1730112871199}
Struct{before=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},after=Struct{id=1,first_name=Jane,last_name=Doe,email=jdoe@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:15,file=mysql-bin.000002,pos=2120,row=0,thread=61},op=u,ts_ms=1730112871207}
Processed a total of 3 messages
```

As an additional exercise, you can extend this data pipeline by configuring a sink connector and exporting these changes to an external system like Artemis Broker.
