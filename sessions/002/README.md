## TLS authentication and custom certificates

The TLS protocol provides communications **security over a computer network**. Encryption without proper identification
is insecure. Hostname verification through common name (CN) or subject alternative name (SAN) protects against man in
the middle attacks, so it should never be disabled in production.

A **public key infrastructure** (PKI) is an arrangement that binds public keys with respective identities of entities (
e.g. organizations, people, applications). The binding is established through a process of registration and issuance of
certificates by a **certificate authority** (CA). The server name indication (SNI) extension is used when having
multiple certificates on the same IP address. This is also used by OpenShift to route external TLS connections (the
Kafka TCP protocol is tunneled).

A TLS certificate contains a public key along with the ownership data and expiration date. Cipher suites contain
algorithms for key exchange, encryption and authentication. A self-signed certificate is secure enough, but only if it
is trusted upfront by the application. It is also possible to create a **wildcard certificate** (e.g. CN=*.example.com),
that can be used by all application running in a specific domain (e.g. OpenShift cluster).

Within a Kafka cluster, in addition to the **client-server communication**, you also need to protect **inter-cluster
communication** and renew certificates when they expire. Most of this work is done by the cluster operator, which is an
example of the added value of running a controller with domain knowledge.

![](images/connections.png)

A Kafka client doesn't need to trust a server certificate when it is signed by a **well-known CA**, because it is
already included in the system truststore (e.g. `$JAVA_HOME/jre/lib/security/cacerts`). Before the encryption starts,
the peers agree to the protocol version and cipher suite to be used, exchange certificates and share encryption keys (
connection overhead). Almost all the problems occur within this initial handshake.

### Example: TLS authentication (mTLS)

[Deploy the Streams operator and Kafka cluster](/sessions/001). Then, apply the configuration changes to enable TLS
authentication and wait for the CO to restart all pods one by one (rolling update). If the Kafka cluster is operated
correctly, it is possible to update the configuration with zero downtime.

```sh
$ kubectl apply -f sessions/002/crs/tls-authn
kafka.kafka.strimzi.io/my-cluster configured
kafkauser.kafka.strimzi.io/my-user created
```

As you can see, the previous command adds a new authentication element to the external listener, which is the endpoint
for clients connecting from outside OpenShift. It also creates a `KafkaUser` resource with a matching configuration.

```sh
$ kubectl get k my-cluster -o yaml | yq e '.spec.kafka.listeners[2]'
authentication:
  type: tls
name: external
port: 9094
tls: true
type: route

$ kubectl get ku my-user -o yaml | yq e '.spec'
authentication:
  type: tls
```

External clients now need to retrieve the self-signed auto-generated cluster CA certificate and add it to their
truststore. They also need to add the user certificate to their keystore. The cluster operator was kind enough to
generate these stores for us and provide them inside a secret. We also need to retrieve the bootstrap URL from the
passthrough route.

```sh
$ kubectl get secret my-user -o "jsonpath={.data['user\.p12']}" | base64 -d > /tmp/keystore.p12
$ kubectl get secret my-user -o "jsonpath={.data['user\.password']}" | base64 -d
zbyegyq9hRJo

$ kubectl get secret my-cluster-cluster-ca-cert -o "jsonpath={.data['ca\.p12']}" | base64 -d > /tmp/truststore.p12
$ kubectl get secret my-cluster-cluster-ca-cert -o "jsonpath={.data['ca\.password']}" | base64 -d
iJBQFEsE7G2e

$ echo $(kubectl get routes my-cluster-kafka-bootstrap -o=jsonpath='{.status.ingress[0].host}{"\n"}'):443
my-cluster-kafka-bootstrap-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com:443
```

We have all required data, so we can configure the client, connect to the cluster and send some messages in a secure
way. Make sure to have the [Kafka client scripts in your path](/sessions/001).

```sh
$ cat <<EOF >/tmp/client.properties
security.protocol = SSL
ssl.keystore.location = /tmp/keystore.p12
ssl.keystore.password = zbyegyq9hRJo
ssl.truststore.location = /tmp/truststore.p12
ssl.truststore.password = iJBQFEsE7G2e
EOF

$ kafka-console-producer.sh --producer.config /tmp/client.properties \
  --bootstrap-server my-cluster-kafka-bootstrap-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com:443 \
  --topic my-topic
>hello
>tls
>^C 
```

When dealing with TLS issues, it is useful to look inside the certificate to verify the configuration and expiration.
For example, let's get the cluster CA certificate which is used to sign all server certificates. We can use
use `kubectl` to do so, but let's suppose we have the output of the must-gather script.

```sh
$ unzip -q report-10-09-2022_16-45-32.zip
$ cat reports/secrets/my-cluster-cluster-ca-cert.yaml | yq e '.data."ca.crt"' | base64 -d > /tmp/ca.crt
$ openssl crl2pkcs7 -nocrl -certfile /tmp/ca.crt | openssl pkcs7 -print_certs -text -noout
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

When the TLS handshake is failing, add `-Djavax.net.debug=ssl:handshake` as client Java option to get more information.
As additional exercise, you can get the clients CA and user certificates to check if the first signs the second.

### Example: custom certificates

Often, security policies don't allow to run a Kafka cluster with self-signed certificates in production. The listener
certificates functionality can be used to configure a custom certificate signed by an external or well-known CA.

Custom certificates are not managed by the operator, so you will be in charge of the renewal process, which requires to
update the listener secret. A brokers rolling update will start automatically in order to make the new certificate
available. This example only shows TLS encryption, but you can also add a custom client certificate for TLS
authentication by setting `tls-external` type in the user custom resource and creating the user secret (subject can only
contain `CN=$USER_NAME`).

Typically, the security team will provide a certificate bundle including the whole trust chain (i.e. root CA +
intermediate CA + listener certificate) and the private key. If that's not the case, you can easily create the bundle
from the individual certificates in PEM format.

```sh
$ cat /tmp/listener.crt /tmp/intermca.crt /tmp/rootca.crt > /tmp/bundle.crt
```

The most important things to verify here are that the listener certificate is not a CA certificate, and it includes a
SAN for each broker route, plus one for the bootstrap route. Alternatively, you can use a wildcard certificate.

```sh
$ kubectl get routes
NAME                         HOST/PORT                                                                         PATH   SERVICES                              PORT   TERMINATION   WILDCARD
my-cluster-kafka-0           my-cluster-kafka-0-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com                  my-cluster-kafka-0                    9094   passthrough   None
my-cluster-kafka-1           my-cluster-kafka-1-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com                  my-cluster-kafka-1                    9094   passthrough   None
my-cluster-kafka-2           my-cluster-kafka-2-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com                  my-cluster-kafka-2                    9094   passthrough   None
my-cluster-kafka-bootstrap   my-cluster-kafka-bootstrap-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com          my-cluster-kafka-external-bootstrap   9094   passthrough   None

$ openssl crl2pkcs7 -nocrl -certfile listener.crt | openssl pkcs7 -print_certs -text -noout
...
X509v3 extensions:
  X509v3 Basic Constraints: critical
    CA:FALSE
  X509v3 Key Usage:
    Digital Signature, Key Encipherment
  X509v3 Extended Key Usage:
    TLS Web Server Authentication, TLS Web Client Authentication
  X509v3 Subject Alternative Name:
    DNS:my-cluster-kafka-bootstrap-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com, DNS:my-cluster-kafka-0-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com, DNS:my-cluster-kafka-1-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com, DNS:my-cluster-kafka-2-test.apps.cluster-8z6kz.8z6kz.sandbox425.opentlc.com
```

In order to try this configuration, we are going to generate our certificate bundle with just one self-signed wildcard
certificate, pretending it was handed over by the security guys (alternatively, you can use Let's Encrypt service).

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
DNS.1=$(kubectl get route my-cluster-kafka-bootstrap -o yaml | yq -e '.status.ingress.[0].routerCanonicalHostname' | sed "s/router-default/*/")
"
$ openssl genrsa -out /tmp/listener.key 2048
$ openssl req -new -x509 -days 3650 -key /tmp/listener.key -out /tmp/bundle.crt -config <(echo "$CONFIG")
```

[Deploy the Streams operator](/sessions/001). Then, deploy the secret containing the custom certificate and the Kafka
cluster containing a reference to that secret.

```sh
$ kubectl create secret generic ext-listener-crt \
  --from-file=/tmp/bundle.crt --from-file=/tmp/listener.key \
  --dry-run=client -o yaml | kubectl replace --force -f -
  
$ kubectl apply -f sessions/002/crs/custom-crt
kafka.kafka.strimzi.io/my-cluster configured

$ kubectl get po
NAME                                              READY   STATUS    RESTARTS   AGE
pod/my-cluster-entity-operator-6b68959588-4klzj   3/3     Running   0          2m4s
pod/my-cluster-kafka-0                            1/1     Running   0          3m34s
pod/my-cluster-kafka-1                            1/1     Running   0          3m34s
pod/my-cluster-kafka-2                            1/1     Running   0          3m34s
pod/my-cluster-zookeeper-0                        1/1     Running   0          5m4s
pod/my-cluster-zookeeper-1                        1/1     Running   0          5m4s
pod/my-cluster-zookeeper-2                        1/1     Running   0          5m4s
```

When the cluster is ready, clients need to trust the external CA and they will be able to connect.
