## Configuring TLS Authentication

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

Next, configure an external listener of type ingress with TLS authentication enabled.

> [!IMPORTANT]
> The NGINX ingress controller must be deployed with SSL passthrough enabled.

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

This command adds an authentication field to the external listener, which serves as the endpoint for external clients connecting via TLS.
It also creates a KafkaUser resource with matching authentication settings.

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

Once the rolling update completes, you can inspect the broker certificate using the following command.

```sh
$ openssl s_client -connect broker-10.my-cluster.f12i.io:443 -servername bootstrap.my-cluster.f12i.io -showcerts 2>/dev/null | grep "subject\|issuer"
subject=O=io.strimzi, CN=my-cluster-kafka
issuer=O=io.strimzi, CN=cluster-ca v0
```

Now you can send messages using an external Kafka client.

> [!NOTE]
> This example uses the console producer tool included in standard Kafka distributions.

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

When troubleshooting TLS issues, examining certificate details helps verify configuration and expiration dates.
For example, let's inspect the cluster CA certificate, which signs all server certificates.
While you can retrieve this using `kubectl`, this example demonstrates working with must-gather script output.
Use the command from session 002 to generate a fresh report from the current cluster.

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

If certificate inspection doesn't reveal the issue, add the `-Djavax.net.debug=ssl:handshake` Java option to the client for detailed handshake information.
As an exercise, retrieve both the clients CA and user certificates to verify the signing chain.

## Using Custom TLS Certificates

Security policies often prohibit self-signed certificates in production environments.
You can configure listeners to use custom certificates signed by an external or well-known Certificate Authority (CA).

Custom certificates are not managed by the Strimzi operator, so you're responsible for the renewal process, which requires updating the listener secret.
The operator triggers a rolling update automatically to apply the new certificate.
This example demonstrates TLS encryption. For TLS authentication with custom client certificates, set `type: tls-external` in the KafkaUser custom resource and create the user secret (the subject must contain only `CN=$USER_NAME`).

> [!NOTE]
> Typically, your security team provides a certificate bundle containing the complete trust chain (root CA + intermediate CA + listener certificate) along with a private key.
> If you receive individual certificates in PEM format, create the bundle by concatenating them:
> ```sh
> $ cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt >/tmp/bundle.crt
> ```

For this example, we'll generate a self-signed certificate bundle to simulate a security team handoff.
A wildcard certificate is used to avoid specifying Subject Alternative Names (SANs) for each broker individually.

> [!IMPORTANT]
> The custom server certificate for a listener must not have the CA flag set, and it must include a Subject Alternative Name (SAN) for each broker address plus the bootstrap address.
> Alternatively, use a wildcard certificate to cover all addresses with a single SAN entry.

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

After the rolling update completes, clients only need to trust the external CA to establish connections.
Since this example uses a self-signed certificate, clients must trust that certificate directly.

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
