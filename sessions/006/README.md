## Using Kafka Connect with Debezium

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Once the cluster is ready, deploy a MySQL instance to serve as the external data source.

```sh
$ kubectl create -f sessions/006/install/mysql.yaml \
  && kubectl wait --for=condition=Ready pod -l app=my-mysql --timeout=300s \
  && kubectl exec my-mysql-0 -- sh -c 'mysql -u root < /tmp/sql/initdb.sql'
persistentvolumeclaim/my-mysql-data created
configmap/my-mysql-cfg created
configmap/my-mysql-env created
configmap/my-mysql-init created
statefulset.apps/my-mysql created
service/my-mysql-svc created
pod/my-mysql-0 condition met
```

Debezium configuration is connector-specific and thoroughly documented.
The `server_id` value must be unique for each server and replication client within the MySQL cluster.
The MySQL user must have appropriate permissions on all databases from which the connector will capture changes.

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

Next, build a custom Kafka Connect image that includes the required connectors.

```sh
# update versions as needed
IMAGE="quay.io/strimzi/kafka:latest-kafka-4.1.1"
CONNECTORS=(
  "https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/2.3.7.Final/debezium-connector-mysql-2.3.7.Final-plugin.tar.gz"
)

mkdir -p /tmp/my-connect/plugins
for url in "${CONNECTORS[@]}"; do
    if [[ "$url" == *.zip ]]; then
        curl -sL "$url" -o /tmp/my-connect/plugins/file.zip && \
          unzip -qq /tmp/my-connect/plugins/file.zip -d /tmp/my-connect/plugins && \
          rm -f /tmp/my-connect/plugins/file.zip
    elif [[ "$url" == *.tar.gz ]]; then
        curl -sL "$url" -o /tmp/my-connect/plugins/file.tar.gz && \
          tar -xzf /tmp/my-connect/plugins/file.tar.gz -C /tmp/my-connect/plugins && \
          rm -f /tmp/my-connect/plugins/file.tar.gz
    fi
done

echo -e "FROM $IMAGE\nCOPY ./plugins/ /opt/kafka/plugins/\nUSER 1001" >/tmp/my-connect/Dockerfile
docker build -t ttl.sh/fvaleri/kafka-connect:24h /tmp/my-connect
docker push ttl.sh/fvaleri/kafka-connect:24h
```

Now deploy Kafka Connect using the custom image.

```sh
$ kubectl create -f sessions/006/install/connect.yaml
kafkaconnect.kafka.strimzi.io/my-connect-cluster created
kafkaconnector.kafka.strimzi.io/mysql-source-connector created

$ kubectl get po
NAME                                              READY   STATUS    RESTARTS   AGE
pod/my-cluster-broker-10                          1/1     Running   0          6m1s
pod/my-cluster-broker-11                          1/1     Running   0          6m1s
pod/my-cluster-broker-12                          1/1     Running   0          6m1s
pod/my-cluster-controller-0                       1/1     Running   0          6m1s
pod/my-cluster-controller-1                       1/1     Running   0          6m1s
pod/my-cluster-controller-2                       1/1     Running   0          6m1s
pod/my-cluster-entity-operator-7bc799c449-8jxmb   2/2     Running   0          5m27s
pod/my-connect-cluster-connect-0                  1/1     Running   0          2m46s
pod/my-mysql-0                                    1/1     Running   0          4m19s
pod/strimzi-cluster-operator-d78fd875b-q9sds      1/1     Running   0          6m30s

$ kubectl get kc my-connect-cluster -o yaml | yq .spec.image
ttl.sh/fvaleri/kafka-connect:24h

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
  - my-mysql
```

To test the data pipeline, create some database changes using SQL queries.

```sh
$ kubectl exec my-mysql-0 -- sh -c 'MYSQL_PWD="changeit" mysql -u admin testdb -e "
  INSERT INTO customers (first_name, last_name, email) VALUES (\"John\", \"Doe\", \"jdoe@example.com\");
  UPDATE customers SET first_name = \"Jane\" WHERE id = 1;
  INSERT INTO customers (first_name, last_name, email) VALUES (\"Max\", \"Power\", \"mpower@example.com\");
  SELECT * FROM customers;"'
id	first_name	last_name	email
1	Jane	Doe	    jdoe@example.com
2	Max 	Power	ddog@example.com
```

The MySQL connector writes change events to a Kafka topic following the naming pattern `serverName.databaseName.tableName`.
The three database changes (insert, update, insert) result in three topic records.
Key record properties include: `op` for the operation type (c=create, r=read for snapshots, u=update, d=delete), `gtid` for the globally unique transaction identifier, `payload.source.ts_ms` for when the database change occurred, and `payload.ts_ms` for when Debezium processed the event.
The notification lag represents the time difference between these two timestamps.

```sh
$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-mysql.testdb.customers --from-beginning --max-messages 3
Struct{after=Struct{id=2,first_name=Max,last_name=Power,email=mpower@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:16,file=mysql-bin.000002,pos=2602,row=0,thread=61},op=c,ts_ms=1730112871209}
Struct{after=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:14,file=mysql-bin.000002,pos=1707,row=0,thread=61},op=c,ts_ms=1730112871199}
Struct{before=Struct{id=1,first_name=John,last_name=Doe,email=jdoe@example.com},after=Struct{id=1,first_name=Jane,last_name=Doe,email=jdoe@example.com},source=Struct{version=2.3.7.Final,connector=mysql,name=my-mysql,ts_ms=1730112871000,db=testdb,table=customers,server_id=111111,gtid=500bc4b7-951a-11ef-aae4-9e82de0bd73c:15,file=mysql-bin.000002,pos=2120,row=0,thread=61},op=u,ts_ms=1730112871207}
Processed a total of 3 messages
```

As an exercise, extend this data pipeline by configuring a sink connector to export these changes to an external system such as Artemis Broker.
