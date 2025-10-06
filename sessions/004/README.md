## Configuring TLS authentication

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Then we configure an external listener of type ingress with TLS authentication.

> [!IMPORTANT]
> The NGINX ingress controller needs to be deployed with SSL passthrough enabled.

```sh
$ kubectl create -f sessions/004/install.yaml \
  && kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        listeners:
          - name: external
            port: 9094
            type: ingress
            tls: true
            authentication:
              type: tls
            configuration:
              class: nginx
              hostTemplate: broker-{nodeId}.my-cluster.f12i.io
              bootstrap:
                host: bootstrap.my-cluster.f12i.io'
kafkauser.kafka.strimzi.io/my-user created            
kafka.kafka.strimzi.io/my-cluster patched
```

The previous command adds a new authentication field to the external listener, which is the endpoint used by clients connecting from outside using TLS.
It also creates a Kafka user resource with a matching configuration.

```sh
$ kubectl get ingress
NAME                         CLASS   HOSTS                              ADDRESS        PORTS     AGE
my-cluster-broker-10         nginx   broker-10.my-cluster.f12i.io       192.168.49.2   80, 443   104s
my-cluster-broker-11         nginx   broker-11.my-cluster.f12i.io       192.168.49.2   80, 443   104s
my-cluster-broker-12         nginx   broker-12.my-cluster.f12i.io       192.168.49.2   80, 443   104s
my-cluster-kafka-bootstrap   nginx   bootstrap.my-cluster.f12i.io       192.168.49.2   80, 443   104s

$ kubectl get ku my-user -o yaml | yq .spec
authentication:
  type: tls
```

When the rolling update is completed, you should be able to see the broker certificate running the following command.

```sh
$ openssl s_client -connect broker-10.my-cluster.f12i.io:443 -servername bootstrap.my-cluster.f12i.io -showcerts 2>/dev/null | grep "subject\|issuer"
subject=O=io.strimzi, CN=my-cluster-kafka
issuer=O=io.strimzi, CN=cluster-ca v0
```

Then, we can try to send some messages using an external Kafka client.

> [!NOTE]
> Here we are using a local console producer tool included in every Kafka distribution.

```sh
$ mkdir -p /tmp/mtls ; \
  export BOOTSTRAP_SERVERS=$(kubectl get k my-cluster -o yaml | yq '.status.listeners.[] | select(.name == "external").bootstrapServers') ; \
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

$ bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP_SERVERS" --topic my-topic \
  --producer.config /tmp/mtls/client.properties
>hello
>world
>^C

$ bin/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP_SERVERS" --topic my-topic \
  --from-beginning --max-messages 2 --consumer.config /tmp/mtls/client.properties
hello
world
Processed a total of 2 messages
```

When dealing with TLS issues, it is useful to look inside the certificate to verify its configuration and expiration.
For example, let's get the cluster CA certificate which is used to sign all server certificates.
We can use use `kubectl` to do so, but let's suppose we have a must-gather script output.
Use the command from the first session to generate a new report from the current cluster.

```sh
$ unzip -p ~/Downloads/report-12-10-2024_11-31-59.zip reports/secrets/my-cluster-cluster-ca-cert.yaml \
  | yq '.data."ca.crt"' | base64 -d | openssl x509 -inform pem -noout -text
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            26:9e:a1:7d:4d:34:cb:6b:ec:98:03:46:fb:7a:82:ad:68:80:bd:8e
        Signature Algorithm: sha512WithRSAEncryption
        Issuer: O=io.strimzi, CN=cluster-ca v0
        Validity
            Not Before: Sep  8 16:28:42 2022 GMT
            Not After : Sep  8 16:28:42 2023 GMT
        Subject: O=io.strimzi, CN=cluster-ca v0
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (4096 bit)
                Modulus:
                    ...
                Exponent: 65537 (0x10001)
        X509v3 extensions:
            X509v3 Subject Key Identifier: 
                2D:1D:63:F6:20:57:33:7D:59:73:DF:15:74:A2:A8:3D:E1:5B:3E:38
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
    Signature Algorithm: sha512WithRSAEncryption
    Signature Value:
        ...
```

If this is not enough to spot the issue, we can add the `-Djavax.net.debug=ssl:handshake` Java option to the client in order to get more details.
As an additional exercise, try to get the clients CA and user certificates to verify if the first signs the second.

## Using custom TLS certificates

Often, security policies don't allow you to run a Kafka cluster with self-signed certificates in production.
Configure the listeners to use a custom certificate signed by an external or well-known CA.

Custom certificates are not managed by the operator, so you will be in charge of the renewal process, which requires an update to the listener secret.
A rolling update will start automatically in order to make the new certificate available.
This example only shows TLS encryption, but you can add a custom client certificate for TLS authentication by setting `type: tls-external` in the `KafkaUser` custom resource and creating the user secret (subject can only contain `CN=$USER_NAME`).

> [!NOTE]
> Typically, the security team will provide a certificate bundle which includes the whole trust chain (i.e. root CA + intermediate CA + listener certificate) and a private key.
> If that's not the case, you can easily create the bundle from individual certificates in PEM format, because you need to trust the whole chain, if any.
> ```sh
> $ cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt >/tmp/bundle.crt
> ```

Here we generate our own certificate bundle with only one self-signed certificate, pretending it was handed over by the security team.
We also use a wildcard certificate so that we don't need to specify all broker SANs.

> [!IMPORTANT]  
> The custom server certificate for a listener must not be a CA and it must include a SAN for each broker address, plus one for the bootstrap address.
> Alternatively, you can use a wildcard certificate to include all addresses with one SAN entry.

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

Now we [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001), and configure an external listener.
Then, we deploy the secret containing the custom certificate and update the Kafka cluster configuration by adding a reference to that secret.

```sh
$ kubectl create secret generic ext-listener-crt \
  --from-file=/tmp/ctls/bundle.crt --from-file=/tmp/ctls/listener.key
secret/ext-listener-crt created
  
$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      listeners:
        - name: external
          port: 9094
          type: ingress
          tls: true
          configuration:
            class: nginx
            hostTemplate: broker-{nodeId}.my-cluster.f12i.io
            bootstrap:
              host: bootstrap.my-cluster.f12i.io
            brokerCertChainAndKey:
              secretName: ext-listener-crt
              certificate: bundle.crt
              key: listener.key'
kafka.kafka.strimzi.io/my-cluster patched
```

When the rolling update is completed, clients just need to trust the external CA and they will be able to connect.
In our case, we don't have a CA, so we just need to trust the self-signed certificate.

```sh
$ export BOOTSTRAP_SERVERS=$(kubectl get k my-cluster -o yaml | yq '.status.listeners.[] | select(.name == "external").bootstrapServers')

$ cat <<EOF >/tmp/ctls/client.properties
config.providers=dir
config.providers.dir.class=org.apache.kafka.common.config.provider.DirectoryConfigProvider
config.providers.dir.param.allowlist.pattern=/tmp/ctls/.*
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.certificates=\${dir:/tmp/ctls:bundle.crt}
EOF

$ bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP_SERVERS" --topic my-topic \
  --producer.config /tmp/ctls/client.properties
>hello
>world
>^C
```
