package it.fvaleri.example;

import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
import org.apache.kafka.common.errors.FencedInstanceIdException;
import org.apache.kafka.common.errors.OutOfOrderSequenceException;
import org.apache.kafka.common.errors.ProducerFencedException;
import org.apache.kafka.common.errors.TopicExistsException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static java.time.Duration.ofSeconds;
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
        System.out.printf("Starting application instance with TID %s%n", instanceId);
        createTopic(inputTopic);
        try (var producer = createKafkaProducer();
             var consumer = createKafkaConsumer()) {
            // called first and once to fence zombies and abort any pending transaction
            producer.initTransactions();
            consumer.subscribe(singleton(inputTopic));

            while (!closed) {
                try {
                    System.out.println("READ: Waiting for new user sentence");
                    ConsumerRecords<String, String> records = consumer.poll(ofSeconds(60));

                    if (!records.isEmpty()) {
                        // begin a new transaction session
                        producer.beginTransaction();

                        Map<String, Integer> wordCountMap = new HashMap<>();
                        int numberOfPartitions = producer.partitionsFor(inputTopic).size();
                        for (int i = 0; i < numberOfPartitions; i++) {
                            // process the record and send downstream
                            System.out.printf("PROCESS: Computing word counts for %s-%d%n", inputTopic, i);
                            wordCountMap.putAll(records.records(new TopicPartition(inputTopic, i))
                                .stream()
                                .flatMap(record -> Stream.of(record.value().split(" ")))
                                .map(word -> Tuple.of(word, 1))
                                .collect(Collectors.toMap(tuple -> tuple.getKey(), t1 -> t1.getValue(), (v1, v2) -> v1 + v2)));
                        }

                        System.out.println("WRITE: Sending offsets and counts atomically");
                        createTopic(outputTopic);
                        wordCountMap.forEach((key, value) -> producer.send(new ProducerRecord<>(outputTopic, key, value.toString())));

                        // checkpoint the progress by sending offsets to group coordinator broker
                        // note that this API is only available for broker >= 2.5
                        producer.sendOffsetsToTransaction(getOffsetsToCommit(consumer), consumer.groupMetadata());

                        // commit the transaction (all sent records should be visible for consumption)
                        producer.commitTransaction();
                    }
                } catch (ProducerFencedException | FencedInstanceIdException | OutOfOrderSequenceException e) {
                    // we can't recover from these exceptions
                    e.printStackTrace();
                    closed = true;
                } catch (KafkaException e) {
                    // abort the transaction and try to continue
                    System.err.printf("Aborting transaction: %s%n", e);
                    producer.abortTransaction();
                }
            }
        } catch (Throwable e) {
            System.err.printf("%s%n", e);
        }
    }

    private static void createTopic(String topicName) {
        Properties props = new Properties();
        props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        try (var admin = Admin.create(props)) {
            admin.createTopics(List.of(new NewTopic(topicName, -1, (short) -1))).all().get();
            System.out.printf("Topic %s created%n", topicName);
        } catch (Throwable e) {
            if (!(e.getCause() instanceof TopicExistsException)) {
                throw new RuntimeException(e);
            }
            System.out.printf("Topic %s already exists%n", topicName);
        }
    }

    private static KafkaProducer<String, String> createKafkaProducer() {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
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

    public static class Tuple {
        private String key;
        private Integer value;

        private Tuple(String key, Integer value) {
            this.key = key;
            this.value = value;
        }

        public static Tuple of(String key, Integer value) {
            return new Tuple(key, value);
        }

        public String getKey() {
            return key;
        }

        public Integer getValue() {
            return value;
        }
    }
}
