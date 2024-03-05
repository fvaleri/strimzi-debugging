## TLS authentication and custom certificates

The Transport Layer Security (TLS) encryption protocol serves as a pivotal component in ensuring the security of communications across computer networks.
However, if encryption is implemented without proper identification mechanisms (CN and SAN), can expose vulnerabilities.

Host verification, facilitated through validation of the Common Name (CN) or Subject Alternative Name (SAN) within a TLS certificate, stands as a crucial safeguard against potential man-in-the-middle attacks.
Consequently, this feature should remain enabled without exception in production environments.

A TLS certificate encapsulates not only the public key but also essential ownership metadata and expiration details.
While a self-signed certificate (where the issuer matches the subject) can offer a baseline level of security, its efficacy hinges on upfront trust establishment by the application.
Furthermore, the creation of wildcard certificates, exemplified by CN formats such as `*.example.com`, provides a means for universal application across specific subdomains.

Cipher suites, comprising algorithms for key exchange, encryption, and authentication, play an integral role in bolstering the security posture of TLS implementations.

Public Key Infrastructure (PKI) frameworks facilitate the binding of public keys with corresponding identities, ranging from organizations to individuals or applications.
This binding process is formalized through registration and certificate issuance, typically overseen by a Certificate Authority (CA).

Within a Kafka cluster, safeguarding both client-server and inter-cluster communications is imperative.
This entails proactive certificate renewal upon expiration, a responsibility adeptly managed by the Strimzi Cluster Operator.
Notably, this operator exemplifies the efficacy of the operator pattern in streamlining cluster management tasks.
The Cluster Operator automates the generation and utilization of two self-signed CAs: one for signing all cluster certificates (cluster CA) and another for user certificates (clients CA).

<p align="center"><img src="images/network.png" height=350/></p>

The server name indication (SNI) extension allows a client to indicate which hostname it is trying to connect to at the start of the TLS handshake.
The server can present multiple certificates on the same IP address and port number.
For example, it is used to route external connections to the right pod when having pass-through routes, and also allows a TCP tunnel through the HTTP reverse proxy.

The Server Name Indication (SNI) extension empowers clients to specify the intended hostname during the TLS handshake initiation.
Leveraging SNI, servers can present multiple certificates on a single IP address and port, facilitating effective routing of external connections to the appropriate Pod.
Additionally, SNI enables TCP tunneling through HTTP reverse proxies.

In Kafka deployments, client-side trust in TLS certificates is unnecessary when they are signed by a well-known CA already included in the system's truststore (e.g., `$JAVA_HOME/jre/lib/security/cacerts`).
In configurations implementing TLS mutual authentication (mTLS), it is imperative for servers to support certificate-to-user identity mapping.
Notably, prior to encryption initiation, peers engage in negotiation concerning protocol version and cipher suite selection, followed by certificate exchange and encryption key sharing, albeit incurring connection overhead.
It is during this initial handshake phase that the bulk of authentication-related issues manifest.

<br/>

---
### Example: TLS authentication (mTLS) using an external listener

First, [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001).
We also add an external listener (if route is not supported, you can use ingress type).

Then, we apply the configuration changes to enable TLS authentication and wait for the Cluster Operator to restart all pods one by one (rolling update).
If the Kafka cluster is operating correctly, it is possible to update the configuration with zero downtime.

```sh
$ kubectl create -f sessions/002/resources \
  && kubectl patch k my-cluster --type merge -p '
    spec:
      kafka:
        listeners:
          - name: external
            port: 9094
            type: route
            tls: true
            authentication:
              type: tls'
kafkauser.kafka.strimzi.io/my-user created            
kafka.kafka.strimzi.io/my-cluster patched
```

The previous command adds a new authentication element to the external listener, which is the endpoint used by clients connecting from outside using TLS.
It also creates a Kafka user resource with a matching configuration.

```sh
$ kubectl get k my-cluster -o yaml | yq .spec.kafka.listeners[0]
authentication:
  type: tls
name: external
port: 9094
tls: true
type: route

$ kubectl get ku my-user -o yaml | yq .spec
authentication:
  type: tls
```

Wait some time for the Kafka brokers to be rolled.
The external clients have to retrieve the bootstrap URL from the passthrough route, configure their keystore and truststore.
Then, we can try to send some messages in a secure way.

```sh
$ BOOTSTRAP_SERVERS=$(kubectl get routes my-cluster-kafka-bootstrap -o jsonpath="{.status.ingress[0].host}"):443 \
  KEYSTORE_LOCATION="/tmp/keystore.p12" KEYSTORE_PASSWORD=$(kubectl get secret my-user -o jsonpath="{.data['user\.password']}" | base64 -d) \
  TRUSTSTORE_LOCATION="/tmp/truststore.p12" TRUSTSTORE_PASSWORD=$(kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.password']}" | base64 -d) \
  ; kubectl get secret my-user -o jsonpath="{.data['user\.p12']}" | base64 -d > $KEYSTORE_LOCATION \
  && kubectl get secret my-cluster-cluster-ca-cert -o jsonpath="{.data['ca\.p12']}" | base64 -d > $TRUSTSTORE_LOCATION
  
$ echo -e "security.protocol = SSL
ssl.keystore.location = $KEYSTORE_LOCATION
ssl.keystore.password = $KEYSTORE_PASSWORD
ssl.truststore.location = $TRUSTSTORE_LOCATION
ssl.truststore.password = $TRUSTSTORE_PASSWORD" >/tmp/client.properties

$ $KAFKA_HOME/bin/kafka-console-producer.sh --producer.config /tmp/client.properties --bootstrap-server $BOOTSTRAP_SERVERS --topic my-topic
>hello
>tls
>^C 
```

When dealing with TLS issues, it is useful to look inside the certificate to verify its configuration and expiration.
For example, let's get the cluster CA certificate which is used to sign all server certificates.
We can use use `kubectl` to do so, but let's suppose we have a must-gather script output.
Use the command from the first session to generate a new report from the current cluster.

```sh
$ unzip -q report-10-09-2022_16-45-32.zip
$ cat reports/secrets/my-cluster-cluster-ca-cert.yaml | yq '.data."ca.crt"' | base64 -d > /tmp/ca.crt
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

<br/>

---
### Example: custom certificates

Often, security policies don't allow you to run a Kafka cluster with self-signed certificates in production.
Configure the listeners to use a custom certificate signed by an external or well-known CA.

Custom certificates are not managed by the operator, so you will be in charge of the renewal process, which requires an update to the listener secret.
A rolling update will start automatically in order to make the new certificate available.
This example only shows TLS encryption, but you can add a custom client certificate for TLS authentication by setting `type: tls-external` in the `KafkaUser` custom resource and creating the user secret (subject can only contain `CN=$USER_NAME`).

Typically, the security team will provide a certificate bundle which includes the whole trust chain (i.e. root CA + intermediate CA + listener certificate) and a private key.
If that's not the case, you can easily create the bundle from individual certificates in PEM format, because you need to trust the whole chain, if any.

```sh
$ cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt > /tmp/bundle.crt
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
$ CONFIG="
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
DNS.1=$(kubectl get route my-cluster-kafka-bootstrap -o yaml | yq .status.ingress.[0].routerCanonicalHostname | sed "s#router-default#*#")
" && openssl genrsa -out /tmp/listener.key 2048 && openssl req -new -x509 -days 3650 -key /tmp/listener.key -out /tmp/bundle.crt -config <(echo "$CONFIG")

$ openssl crl2pkcs7 -nocrl -certfile /tmp/bundle.crt | openssl pkcs7 -print_certs -text -noout | grep DNS
                DNS:*.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com
```

Now we [deploy the Strimzi Cluster Operator and Kafka cluster](/sessions/001), and set the external listener.
Then, we deploy the secret containing the custom certificate and update the Kafka cluster configuration by adding a reference to that secret.

```sh
$ kubectl create secret generic ext-listener-crt \
  --from-file=/tmp/bundle.crt --from-file=/tmp/listener.key \
  --dry-run=client -o yaml | kubectl replace --force -f -
secret/ext-listener-crt replaced
  
$ kubectl patch k my-cluster --type merge -p '
  spec:
    kafka:
      listeners:
        - name: external
          port: 9094
          type: route
          tls: true
          configuration:
            brokerCertChainAndKey:
              secretName: ext-listener-crt
              certificate: bundle.crt
              key: listener.key'
kafka.kafka.strimzi.io/my-cluster patched

$ kubectl get k my-cluster -o yaml | yq .spec.kafka.listeners[0]
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
$ BOOTSTRAP_SERVERS=$(kubectl get ingress my-cluster-kafka-bootstrap -o jsonpath="{.status.ingress[0].host}"):443 \
  CERT_LOCATION="/tmp/bundle.crt" TRUSTSTORE_LOCATION="/tmp/truststore.p12" TRUSTSTORE_PASSWORD="changeit"
  
$ rm -rf $TRUSTSTORE_LOCATION && keytool -keystore $TRUSTSTORE_LOCATION -storetype PKCS12 -alias my-cluster \
  -storepass $TRUSTSTORE_PASSWORD -keypass $TRUSTSTORE_PASSWORD -import -file $CERT_LOCATION -noprompt
Certificate was added to keystore

$ cat <<EOF >/tmp/client.properties
security.protocol = SSL
ssl.truststore.location = $TRUSTSTORE_LOCATION
ssl.truststore.password = $TRUSTSTORE_PASSWORD
EOF

$ $KAFKA_HOME/bin/kafka-console-producer.sh --producer.config /tmp/client.properties --bootstrap-server $BOOTSTRAP_SERVERS --topic my-topic
>hello
>custom
>tls
>^C
```
