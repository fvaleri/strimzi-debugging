package it.fvaleri.example;

import io.apicurio.registry.rest.client.RegistryClient;
import io.apicurio.registry.rest.client.RegistryClientFactory;
import io.apicurio.registry.rest.client.exception.NotFoundException;
import io.apicurio.registry.rest.v2.beans.IfExists;
import io.apicurio.registry.serde.SerdeConfig;
import io.apicurio.registry.serde.avro.AvroKafkaDeserializer;
import io.apicurio.registry.serde.avro.AvroKafkaSerializer;
import org.apache.avro.Schema;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericRecord;
import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.config.SslConfigs;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Collections;
import java.util.Properties;

public class Main {
    private static String bootstrapServers;
    private static String registryUrl;
    private static String sslTruststoreLocation;
    private static String sslTruststorePassword;

    private static final String TOPIC_NAME = "my-topic";
    private static final String ARTIFACT_GROUP = "default";
    private static final String ARTIFACT_ID = TOPIC_NAME + "-value";

    static {
        if (System.getenv("BOOTSTRAP_SERVERS") != null) {
            bootstrapServers = System.getenv("BOOTSTRAP_SERVERS");
        }
        if (System.getenv("REGISTRY_URL") != null) {
            registryUrl = System.getenv("REGISTRY_URL");
        }
        if (System.getenv("SSL_TRUSTSTORE_LOCATION") != null) {
            sslTruststoreLocation = System.getenv("SSL_TRUSTSTORE_LOCATION");
        }
        if (System.getenv("SSL_TRUSTSTORE_PASSWORD") != null) {
            sslTruststorePassword = System.getenv("SSL_TRUSTSTORE_PASSWORD");
        }
    }

    public static void main(String[] args) {
        try (var producer = new KafkaProducer<String, GenericRecord>(producerConfig());
             var consumer = new KafkaConsumer<Long, GenericRecord>(consumerConfig())) {

            // get the schema by group and id
            RegistryClient client = RegistryClientFactory.create(registryUrl);
            String schemaData = null;
            try (InputStream latestArtifact = client.getLatestArtifact(ARTIFACT_GROUP, ARTIFACT_ID)) {
                schemaData = toString(latestArtifact);
            } catch (NotFoundException e) {
                System.err.println("Schema not registered");
                System.exit(1);
            }

            System.out.println("Producing records");
            Schema schema = new Schema.Parser().parse(schemaData);
            for (int i = 0; i < 5; i++) {
                // we use the generic record instead of generating classes from the schema
                GenericRecord record = new GenericData.Record(schema);
                record.put("Message", "Hello");
                record.put("Time", System.currentTimeMillis());
                ProducerRecord<String, GenericRecord> producedRecord = new ProducerRecord<>(TOPIC_NAME, null, record);
                producer.send(producedRecord);
            }
            System.out.println("Records produced");

            System.out.println("Consuming all records");
            consumer.subscribe(Collections.singletonList(TOPIC_NAME));
            while (true) {
                // the globalId is sent with the payload and used to lookup the schema
                ConsumerRecords<Long, GenericRecord> records = consumer.poll(Duration.ofSeconds(5));
                records.forEach(record -> {
                    GenericRecord value = record.value();
                    System.out.printf("Record: %s-%d%n", value.get("Message"), value.get("Time"));
                });
                if (records.count() > 0) {
                    System.exit(0);
                }
            }
        } catch (Throwable t) {
            System.err.printf("%s%n", t);
            System.exit(1);
        }
    }

    private static Properties producerConfig() {
        Properties props = new Properties();

        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "producer-" + System.currentTimeMillis());
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());

        // use Avro Serializer
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, AvroKafkaSerializer.class.getName());

        // set Service Registry URL
        props.put(SerdeConfig.REGISTRY_URL, registryUrl);
        props.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, Boolean.TRUE);
        props.put(SerdeConfig.AUTO_REGISTER_ARTIFACT_IF_EXISTS, IfExists.RETURN.name());

        addSharedConfig(props);
        return props;
    }

    private static Properties consumerConfig() {
        Properties props = new Properties();

        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.CLIENT_ID_CONFIG, "consumer-" + System.currentTimeMillis());
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "my-group");
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());

        // use Avro Deserializer
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, AvroKafkaDeserializer.class.getName());

        // set Service Registry URL
        props.put(SerdeConfig.REGISTRY_URL, registryUrl);
        props.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, Boolean.TRUE);
        props.put(SerdeConfig.AUTO_REGISTER_ARTIFACT_IF_EXISTS, IfExists.RETURN.name());

        addSharedConfig(props);
        return props;
    }

    private static void addSharedConfig(Properties props) {
        if (sslTruststoreLocation != null) {
            props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG, "SSL");
            props.put(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG, sslTruststoreLocation);
            props.put(SslConfigs.SSL_TRUSTSTORE_PASSWORD_CONFIG, sslTruststorePassword);
            props.put(SslConfigs.SSL_TRUSTSTORE_TYPE_CONFIG, "PKCS12");
        }
    }

    private static String toString(InputStream data) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] buff = new byte[64];
        int count;
        while ((count = data.read(buff)) != -1) {
            baos.write(buff, 0, count);
        }
        return new String(baos.toByteArray(), StandardCharsets.UTF_8);
    }
}
