## Configuring TLS Authentication

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

In this example we configure an external listener with `nodeport` type and enable TLS authentication.
The operator takes care of creating a NodePort service for each broker that open a dedicated port on all Kubernetes nodes.
This is an easy way to allow applications running outside of Kubernetes to directly connect to brokers.

The listener configuration allows to specify which ports we want to open for each broker and the advertised address and port.
We also create a nice address in our /etc/hosts file, which has the same effect of assigning a DNS record to our Minikube node.

```sh
$ echo "$(minikube ip) bootstrap.my-cluster.f12i.io broker-10.my-cluster.f12i.io \
  broker-11.my-cluster.f12i.io broker-12.my-cluster.f12i.io" | sudo tee -a /etc/hosts
92.168.49.2 bootstrap.my-cluster.f12i.io broker-10.my-cluster.f12i.io broker-11.my-cluster.f12i.io broker-12.my-cluster.f12i.io

$ kubectl patch k my-cluster --type merge --patch-file sessions/004/install/tls-auth.yaml
kafka.kafka.strimzi.io/my-cluster patched
```

After the rolling update completes, we can check the services and inspect the broker certificate.

```sh
$ kubectl get svc | grep NodePort
my-cluster-broker-10                  NodePort    10.110.157.36    <none>        9094:32110/TCP               84s
my-cluster-broker-11                  NodePort    10.108.78.230    <none>        9094:32111/TCP               84s
my-cluster-broker-12                  NodePort    10.109.177.251   <none>        9094:32112/TCP               84s
my-cluster-kafka-external-bootstrap   NodePort    10.97.31.189     <none>        9094:32100/TCP               84s

$ openssl s_client -connect bootstrap.my-cluster.f12i.io:32100 -showcerts 2>/dev/null | grep "subject\|issuer"
subject=O=io.strimzi, CN=my-cluster-kafka
issuer=O=io.strimzi, CN=cluster-ca v0
```

Before running some tests, we also need to create a user for TLS authentication.

```sh
$ kubectl create -f sessions/004/install/user.yaml
kafkauser.kafka.strimzi.io/my-user created
```

Now we can send and consume some messages using an external client, like the one bundled with Kafka.

```sh
$ mkdir -p /tmp/mtls ; export BOOTSTRAP_SERVERS="bootstrap.my-cluster.f12i.io:32100" ; \
  kubectl get k my-cluster -o yaml | yq '.status.listeners.[] | select(.name == "external").certificates[0]' > /tmp/mtls/cluster-ca.crt ; \
  kubectl get secret my-user -o yaml | yq '.data["user.crt"]' | base64 -d > /tmp/mtls/user.crt ; \
  kubectl get secret my-user -o yaml | yq '.data["user.key"]' | base64 -d > /tmp/mtls/user.key

$ cat <<EOF >/tmp/mtls/client.properties
config.providers=dir
config.providers.dir.class=org.apache.kafka.common.config.provider.DirectoryConfigProvider
config.providers.dir.param.allowlist.pattern=/tmp/mtls/.*
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.certificates=\${dir:/tmp/mtls:cluster-ca.crt}
ssl.keystore.type=PEM
ssl.keystore.certificate.chain=\${dir:/tmp/mtls:user.crt}
ssl.keystore.key=\${dir:/tmp/mtls:user.key}
EOF

$ kubectl-kafka bin/kafka-topics.sh --version
pod/kafka-tools created
4.3.1

$ kubectl cp /tmp/mtls kafka-tools:/tmp/mtls

$ echo -e "hello\nworld" | \
  kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP_SERVERS" --topic my-topic \
    --command-config /tmp/mtls/client.properties

$ kubectl-kafka bin/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP_SERVERS" --topic my-topic \
  --from-beginning --max-messages 2 --command-config /tmp/mtls/client.properties
hello
world
Processed a total of 2 messages
```

## Using Custom TLS Certificates

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Security policies often prohibit self-signed certificates in production environments.
We can configure listeners to use custom certificates signed by an external or well-known Certificate Authority (CA).

Custom certificates are not managed by the operator, so you're responsible for the renewal process, which requires updating the listener secret.
The operator triggers a rolling update automatically to apply the new certificate.
This example demonstrates TLS encryption.

> [!NOTE]
> Typically, you have a certificate bundle containing the trust chain (root CA + intermediate CA + end entity certificate) along with a private key.
> Individual certificates in PEM format can be bundled by simply concatenating them:
> ```sh
> $ cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt >/tmp/bundle.crt
> ```

For this example, we'll use a self-signed wildcard certificate.

> [!NOTE]
> With the wildcard configuration we don't need to add a Subject Alternative Names (SAN) for each broker.

```sh
$ CONFIG="
[req]
prompt=no
distinguished_name=dn
x509_extensions=ext
[dn]
countryName=IT
stateOrProvinceName=Rome
organizationName=Fede
commonName=my-cluster
[ext]
subjectAltName=@san
[san]
DNS.1=*.my-cluster.f12i.io
" ; mkdir -p /tmp/ctls ; openssl genrsa -out /tmp/ctls/listener.key 2048 ; \
  openssl req -new -x509 -days 3650 -key /tmp/ctls/listener.key -out /tmp/ctls/bundle.crt -config <(echo "$CONFIG")
```

Now [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001), then configure an external listener.
Next, create a secret containing the custom certificate and update the Kafka cluster configuration to reference it.

```sh
$ kubectl create secret generic ext-listener-crt \
  --from-file=/tmp/ctls/bundle.crt --from-file=/tmp/ctls/listener.key
secret/ext-listener-crt created
  
$ kubectl patch k my-cluster --type merge --patch-file sessions/004/insatll/custom-tls.yaml
kafka.kafka.strimzi.io/my-cluster patched
```

After the rolling update completes, clients only need to trust the external CA to establish connections.
Since this example uses a self-signed certificate, clients must trust that certificate directly.

```sh
$ cat <<EOF >/tmp/ctls/client.properties
config.providers=dir
config.providers.dir.class=org.apache.kafka.common.config.provider.DirectoryConfigProvider
config.providers.dir.param.allowlist.pattern=/tmp/ctls/.*
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.certificates=\${dir:/tmp/ctls:bundle.crt}
EOF

$ kubectl-kafka bin/kafka-topics.sh --version
pod/kafka-tools created
4.3.1

$ kubectl cp /tmp/ctls kafka-tools:/tmp/ctls

$ echo -e "hello\nworld" | \
  kubectl-kafka bin/kafka-console-producer.sh --bootstrap-server bootstrap.my-cluster.f12i.io:32100 --topic my-topic \
    --producer.config /tmp/ctls/client.properties
```
