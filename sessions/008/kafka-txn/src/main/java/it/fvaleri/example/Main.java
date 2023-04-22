package it.fvaleri.example;

import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.consumer.NoOffsetForPartitionException;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.consumer.OffsetOutOfRangeException;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
import org.apache.kafka.common.errors.FencedInstanceIdException;
import org.apache.kafka.common.errors.OutOfOrderSequenceException;
import org.apache.kafka.common.errors.ProducerFencedException;
import org.apache.kafka.common.errors.SerializationException;
import org.apache.kafka.common.errors.TopicExistsException;
import org.apache.kafka.common.errors.UnsupportedVersionException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.stream.Collectors;

import static java.time.Duration.ofSeconds;
import static java.util.Collections.emptyList;
import static java.util.Collections.singleton;

public class Main {
    private static String bootstrapServers, groupId, instanceId, inputTopic, outputTopic;
    private static volatile boolean closed = false;

    static {
        if (System.getenv("BOOTSTRAP_SERVERS") != null) {
            bootstrapServers = System.getenv("BOOTSTRAP_SERVERS");
        }
        if (System.getenv("GROUP_ID") != null) {
            groupId = System.getenv("GROUP_ID");
        }
        if (System.getenv("INSTANCE_ID") != null) {
            instanceId = System.getenv("INSTANCE_ID");
        }
        if (System.getenv("INPUT_TOPIC") != null) {
            inputTopic = System.getenv("INPUT_TOPIC");
        }
        if (System.getenv("OUTPUT_TOPIC") != null) {
            outputTopic = System.getenv("OUTPUT_TOPIC");
        }
    }

    public static void main(String[] args) {
        System.out.printf("Starting instance %s%n", instanceId);
        try (var producer = createKafkaProducer();
             var consumer = createKafkaConsumer()) {
            createTopics(inputTopic, outputTopic);
            // called first and once to fence zombies and abort any pending transaction
            producer.initTransactions();
            consumer.subscribe(singleton(inputTopic));

            while (!closed) {
                try {
                    System.out.println("Waiting for new data");
                    ConsumerRecords<String, String> records = consumer.poll(ofSeconds(30));
                    if (!records.isEmpty()) {
                        // begin a new transaction session
                        producer.beginTransaction();

                        System.out.println("Processing records and sending downstream");
                        for (ConsumerRecord<String, String> record : records) {
                            String newValue = new StringBuilder(record.value()).reverse().toString();
                            ProducerRecord<String, String> newRecord =
                                new ProducerRecord<>(outputTopic, record.key(), newValue);
                            producer.send(newRecord);
                        }

                        // checkpoint the progress by sending offsets to group coordinator broker
                        // note that this API is only available for broker >= 2.5
                        producer.sendOffsetsToTransaction(getOffsetsToCommit(consumer), consumer.groupMetadata());

                        // commit the transaction including offsets
                        producer.commitTransaction();
                    }
                } catch (AuthorizationException | UnsupportedVersionException | ProducerFencedException
                         | FencedInstanceIdException | OutOfOrderSequenceException | SerializationException e) {
                    // we can't recover from these exceptions
                    e.printStackTrace();
                    closed = true;
                } catch (OffsetOutOfRangeException | NoOffsetForPartitionException e) {
                    // invalid or no offset found without auto.reset.policy
                    System.out.println("Invalid or no offset found, using latest");
                    consumer.seekToEnd(emptyList());
                    consumer.commitSync();
                } catch (KafkaException e) {
                    // abort the transaction and retry
                    System.err.printf("Aborting transaction: %s%n", e);
                    producer.abortTransaction();
                }
            }
        } catch (Throwable e) {
            System.err.printf("%s%n", e);
        }
    }

    private static KafkaProducer<String, String> createKafkaProducer() {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "client-" + UUID.randomUUID());
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        // transactionalId must be the same between different produce process incarnations
        props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, instanceId);
        props.put(ProducerConfig.TRANSACTION_TIMEOUT_CONFIG, 60_000);
        return new KafkaProducer<>(props);
    }

    private static KafkaConsumer<String, String> createKafkaConsumer() {
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.CLIENT_ID_CONFIG, "client-" + UUID.randomUUID());
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        props.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
        // consumer can set groupInstanceId to avoid unnecessary rebalances
        props.put(ConsumerConfig.GROUP_INSTANCE_ID_CONFIG, instanceId);
        // all records are fetched with read_committed but ongoing and aborted transactions are ignored
        props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
        return new KafkaConsumer<>(props);
    }

    private static Map<TopicPartition, OffsetAndMetadata> getOffsetsToCommit(KafkaConsumer<String, String> consumer) {
        Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
        for (TopicPartition topicPartition : consumer.assignment()) {
            offsets.put(topicPartition, new OffsetAndMetadata(consumer.position(topicPartition), null));
        }
        return offsets;
    }

    private static void createTopics(String... topicNames) {
        Properties props = new Properties();
        props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(AdminClientConfig.CLIENT_ID_CONFIG, "client" + UUID.randomUUID());
        try (Admin admin = Admin.create(props)) {
            // use default RF to avoid NOT_ENOUGH_REPLICAS error with minISR>1
            short replicationFactor = -1;
            List<NewTopic> newTopics = Arrays.stream(topicNames)
                .map(name -> new NewTopic(name, -1, replicationFactor))
                .collect(Collectors.toList());
            try {
                admin.createTopics(newTopics).all().get();
                System.out.printf("Created topics: %s%n", Arrays.toString(topicNames));
            } catch (ExecutionException e) {
                if (!(e.getCause() instanceof TopicExistsException)) {
                    throw e;
                }
            }
        } catch (Exception e) {
            throw new RuntimeException("Topics creation error", e);
        }
    }
}
