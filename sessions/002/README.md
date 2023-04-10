# TLS authentication and custom certificates

The TLS encryption protocol provides communications security over a computer network.
Encryption without proper identification is insecure.
Hostname verification using a common name (CN) or subject alternative name (SAN) in a TLS certificate protects against man-in-the-middle attacks, so it should never be disabled in production.

A TLS certificate contains the public key along with the ownership data and expiration date.
A self-signed certificate (Issuer == Subject) is secure enough, but only if it is trusted upfront by the application.
It is also possible to create a wildcard certificate (e.g. `commonName=*.example.com`), that can be used by all applications running in a specific subdomain (e.g. an OpenShift cluster).
Cipher suites contain algorithms for key exchange, encryption and authentication.

A public key infrastructure (PKI) is an arrangement that binds public keys with respective identities, such as organizations, people, or applications.
The binding is established through a process of registration and issuance of certificates by a certificate authority (CA).

Within a Kafka cluster, in addition to the client-server communication, inter-cluster communication must be protected and certificates renewed when they expire.
All of this work is done by the AMQ Streams Cluster Operator, which is a great example of how the operator simplifies cluster management.
Two self-signed CAs are automatically generated and used to sign all cluster (cluster CA) and user (clients CA) certificates.

**AMQ Streams communication secured by TLS**
![tls communication](images/connections.png)

The server name indication (SNI) extension allows a client to indicate which hostname it is trying to connect to at the start of the TLS handshake.
The server can present multiple certificates on the same IP address and port number.
For example, it is used by OpenShift to route external connections to the right pod when having passthrough routes, and also allows a TCP tunnel through the HTTP reverse proxy.

Kafka clients don't need to trust TLS certificates when they are signed by a well-known CA that is already included in the system truststore (e.g. `$JAVA_HOME/jre/lib/security/cacerts`).
When enabling TLS mutual authentication (mTLS), the server should also support the certificate CN mapping to the user identity.
Before the encryption starts, the peers agree to the protocol version and cipher suite to be used, exchange certificates and share encryption keys (connection overhead).
Almost all authentication problems occur within this initial handshake.

# Example: TLS authentication (mTLS) using an external listener

First, we [deploy the AMQ Streams operator and Kafka cluster](/sessions/001).
Then, we apply the configuration changes to enable TLS authentication and wait for the Cluster Operator to restart all pods one by one (rolling update).
If the Kafka cluster is operating correctly, it is possible to update the configuration with zero downtime.

```sh
kubectl apply -f sessions/002/resources/mtls
kafka.kafka.strimzi.io/my-cluster configured
kafkauser.kafka.strimzi.io/my-user created
```

The previous command adds a new authentication element to the external listener, which is the endpoint used by clients connecting from outside OpenShift using TLS.
It also creates a Kafka user resource with a matching configuration.

```sh
kubectl get k my-cluster -o yaml | yq '.spec.kafka.listeners[2]'
authentication:
  type: tls
name: external
port: 9094
tls: true
type: route

kubectl get ku my-user -o yaml | yq '.spec'
authentication:
  type: tls
```

The external clients have to retrieve the bootstrap URL from the passthrough route, configure their keystore and truststore.
Then, we can try to send some messages in a secure way.

```sh
BOOTSTRAP_SERVERS=$(kubectl get routes my-cluster-kafka-bootstrap -o jsonpath="{.status.ingress[0].host}"):443 \
  KEYSTORE_LOCATION="/tmp/keystore.p12" KEYSTORE_PASSWORD=$(kubectl get secret my-user -o jsonpath="{.data['user\.password']}" | base64 -d) \
  TRUSTSTORE_LOCATION="/tmp/truststore.p12" TRUSTSTORE_PASSWORD=$(kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.password']}" | base64 -d) \
  ; kubectl get secret my-user -o jsonpath="{.data['user\.p12']}" | base64 -d > $KEYSTORE_LOCATION \
  && kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.p12']}" | base64 -d > $TRUSTSTORE_LOCATION
  
cat <<EOF >/tmp/client.properties
security.protocol = SSL
ssl.keystore.location = $KEYSTORE_LOCATION
ssl.keystore.password = $KEYSTORE_PASSWORD
ssl.truststore.location = $TRUSTSTORE_LOCATION
ssl.truststore.password = $TRUSTSTORE_PASSWORD
EOF

kafka-console-producer.sh --producer.config /tmp/client.properties --bootstrap-server $BOOTSTRAP_SERVERS --topic my-topic
>hello
>tls
>^C 
```

When dealing with TLS issues, it is useful to look inside the certificate to verify its configuration and expiration.
For example, let's get the cluster CA certificate which is used to sign all server certificates.
We can use use `kubectl` to do so, but let's suppose we have a must-gather script output.
Use the command from the first session to generate a new report from the current cluster.

```sh
unzip -q report-10-09-2022_16-45-32.zip
cat reports/secrets/my-cluster-cluster-ca-cert.yaml | yq '.data."ca.crt"' | base64 -d > /tmp/ca.crt
openssl crl2pkcs7 -nocrl -certfile /tmp/ca.crt | openssl pkcs7 -print_certs -text -noout
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

# Example: custom certificates

Often, security policies don't allow you to run a Kafka cluster with self-signed certificates in production.
Configure the listeners to use a custom certificate signed by an external or well-known CA.

Custom certificates are not managed by the operator, so you will be in charge of the renewal process, which requires an update to the listener secret.
A rolling update will start automatically in order to make the new certificate available.
This example only shows TLS encryption, but you can add a custom client certificate for TLS authentication by setting `type: tls-external` in the `KafkaUser` custom resource and creating the user secret (subject can only contain `CN=$USER_NAME`).

Typically, the security team will provide a certificate bundle which includes the whole trust chain (i.e. root CA + intermediate CA + listener certificate) and a private key.
If that's not the case, you can easily create the bundle from individual certificates in PEM format, because you need to trust the whole chain, if any.

```sh
cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt > /tmp/bundle.crt
```

It's important to note that the custom server certificate for a listener must not be a CA and it must include a SAN for each broker route, plus one for the bootstrap route.
This is an example of how it looks.

```sh
...
X509v3 extensions:
  X509v3 Basic Constraints: critical
    CA:FALSE
  X509v3 Key Usage:
    Digital Signature, Key Encipherment
  X509v3 Extended Key Usage:
    TLS Web Server Authentication, TLS Web Client Authentication
  X509v3 Subject Alternative Name:
    DNS:my-cluster-kafka-bootstrap-test.apps.example.com, DNS:my-cluster-kafka-0-test.apps.example.com, DNS:my-cluster-kafka-1-test.apps.example.com, DNS:my-cluster-kafka-2-test.apps.example.com
```

Just for convenience, we generate our own certificate bundle with only one self-signed certificate, pretending it was handed over by the security team.
We use a wildcard certificate so that we don't need to specify all broker SANs.

```sh
CONFIG="
[req]
prompt=no
distinguished_name=dn
x509_extensions=ext
[dn]
countryName=IT
stateOrProvinceName=Rome
organizationName=RedHat
commonName=my-cluster
[ext]
subjectAltName=@san
[san]
DNS.1=$(kubectl get route my-cluster-kafka-bootstrap -o yaml | yq '.status.ingress.[0].routerCanonicalHostname' | sed "s#router-default#*#")
"
openssl genrsa -out /tmp/listener.key 2048
openssl req -new -x509 -days 3650 -key /tmp/listener.key -out /tmp/bundle.crt -config <(echo "$CONFIG")

openssl crl2pkcs7 -nocrl -certfile /tmp/bundle.crt | openssl pkcs7 -print_certs -text -noout | grep DNS
                DNS:*.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com
```

Now we [deploy the AMQ Streams operator and Kafka cluster](/sessions/001).
Then, we deploy the secret containing the custom certificate and update the Kafka cluster configuration by adding a reference to that secret.

```sh
kubectl create secret generic ext-listener-crt \
  --from-file=/tmp/bundle.crt --from-file=/tmp/listener.key \
  --dry-run=client -o yaml | kubectl replace --force -f -
  
kubectl apply -f sessions/002/resources/ccrt
kafka.kafka.strimzi.io/my-cluster configured

kubectl get k my-cluster -o yaml | yq '.spec.kafka.listeners[2]'
configuration:
  brokerCertChainAndKey:
    certificate: bundle.crt
    key: listener.key
    secretName: ext-listener-crt
name: external
port: 9094
tls: true
type: route
```

When the cluster is ready (rolling update is complete), clients just need to trust the external CA and they will be able to connect.
In our case, we don't have a CA, so we just need to trust the self-signed certificate.

```sh
BOOTSTRAP_SERVERS=$(kubectl get routes my-cluster-kafka-bootstrap -o jsonpath="{.status.ingress[0].host}"):443 \
  CERT_LOCATION="/tmp/bundle.crt" TRUSTSTORE_LOCATION="/tmp/truststore.p12" TRUSTSTORE_PASSWORD="changeit"
  
rm -rf $TRUSTSTORE_LOCATION && keytool -keystore $TRUSTSTORE_LOCATION -storetype PKCS12 -alias my-cluster \
  -storepass $TRUSTSTORE_PASSWORD -keypass $TRUSTSTORE_PASSWORD -import -file $CERT_LOCATION -noprompt
Certificate was added to keystore

cat <<EOF >/tmp/client.properties
security.protocol = SSL
ssl.truststore.location = $TRUSTSTORE_LOCATION
ssl.truststore.password = $TRUSTSTORE_PASSWORD
EOF

kafka-console-producer.sh --producer.config /tmp/client.properties --bootstrap-server $BOOTSTRAP_SERVERS --topic my-topic
>hello
>custom
>tls
>^C
```
