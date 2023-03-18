# Streams debugging

This project contains a series of debugging sessions for Red Hat AMQ Streams (LTS).
They assume user level knowledge about Red Hat OpenShift and Apache Kafka.
The examples are not meant to be exhaustive, but just a way to show common scenarios and tools.
Most of them require an OpenShift cluster with 3 worker nodes (e.g. 3x `m5.4xlarge`) and a user with admin permissions.
Contributions are welcomed.

## Outline

1. [Kafka introduction and deployments](/sessions/001)
2. [TLS authentication and custom certificates](/sessions/002)
3. [Schema registry and why it is useful](/sessions/003)
4. [Kafka Connect and change data capture](/sessions/004)
5. [Mirror Maker and disaster recovery](/sessions/005)
6. [Storage requirements and volume recovery](/sessions/006)
7. [Cruise Control and unbalanced clusters](/sessions/007)
8. [Transactions and how to rollback](/sessions/008)
