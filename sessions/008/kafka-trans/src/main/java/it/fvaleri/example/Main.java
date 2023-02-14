package it.fvaleri.example;

import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.KafkaAdminClient;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
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
    private static String bootstrapServers, groupId, transactionalId, inputTopic, outputTopic;
    private static boolean closed = false;

    static {
        if (System.getenv("BOOTSTRAP_SERVERS") != null) {
            bootstrapServers = System.getenv("BOOTSTRAP_SERVERS");
        }
        if (System.getenv("GROUP_ID") != null) {
            groupId = System.getenv("GROUP_ID");
        }
        if (System.getenv("TRANSACTIONAL_ID") != null) {
            transactionalId = System.getenv("TRANSACTIONAL_ID");
        }
        if (System.getenv("INPUT_TOPIC") != null) {
            inputTopic = System.getenv("INPUT_TOPIC");
        }
        if (System.getenv("OUTPUT_TOPIC") != null) {
            outputTopic = System.getenv("OUTPUT_TOPIC");
        }
    }

    public static void main(String[] args) {
        System.out.printf("Starting application instance with TID %s%n", transactionalId);
        createTopic(inputTopic);
        try (var producer = createKafkaProducer();
             var consumer = createKafkaConsumer()) {
            // transaction APIs are all blocking with a max.block.ms timeout
            // called once to fence zombies, abort any pending TX, and get a new session (pid+epoch)
            producer.initTransactions();

            while (!closed) {
                try {
                    System.out.println("READ: Waiting for new user sentence");
                    ConsumerRecords<String, String> consumerRecords = consumer.poll(ofSeconds(60));

                    if (!consumerRecords.isEmpty()) {
                        producer.beginTransaction();

                        Map<String, Integer> wordCountMap = new HashMap<>();
                        int numberOfPartitions = producer.partitionsFor(inputTopic).size();
                        for (int i = 0; i < numberOfPartitions; i++) {
                            System.out.printf("PROCESS: Computing word counts for %s-%d%n", inputTopic, i);
                            wordCountMap.putAll(consumerRecords.records(new TopicPartition(inputTopic, i))
                                .stream()
                                .flatMap(record -> Stream.of(record.value().split(" ")))
                                .map(word -> Tuple.of(word, 1))
                                .collect(Collectors.toMap(tuple -> tuple.getKey(), t1 -> t1.getValue(), (v1, v2) -> v1 + v2)));
                        }

                        System.out.println("WRITE: Sending offsets and counts atomically");
                        createTopic(outputTopic);
                        wordCountMap.forEach((key, value) -> producer.send(new ProducerRecord<>(outputTopic, key, value.toString())));
                        // notifies the coordinator about consumed offsets, which should be committed at the same time as the transaction
                        producer.sendOffsetsToTransaction(getOffsetsToCommit(consumerRecords), consumer.groupMetadata());
                        producer.commitTransaction();
                    }
                } catch (ProducerFencedException | OutOfOrderSequenceException | AuthorizationException e) {
                    // we can't recover from these exceptions
                    closed = true;
                } catch (KafkaException e) {
                    // abort the transaction and try again
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
        try (var admin = KafkaAdminClient.create(props)) {
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
        System.out.println("Creating transactional producer");
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        // must be the same between different produce process incarnations
        props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, transactionalId);
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.TRANSACTION_TIMEOUT_CONFIG, 60_000);
        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        return producer;
    }

    private static KafkaConsumer<String, String> createKafkaConsumer() {
        System.out.println("Creating transactional consumer");
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        // fetch all but ignore records from ongoing and aborted transactions
        props.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
        props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
        consumer.subscribe(singleton(inputTopic));
        return consumer;
    }

    private static Map<TopicPartition, OffsetAndMetadata> getOffsetsToCommit(ConsumerRecords<String, String> consumerRecords) {
        Map<TopicPartition, OffsetAndMetadata> offsetsToCommit = new HashMap<>();
        for (TopicPartition partition : consumerRecords.partitions()) {
            List<ConsumerRecord<String, String>> partitionedRecords = consumerRecords.records(partition);
            long offset = partitionedRecords.get(partitionedRecords.size() - 1).offset();
            // we need to commit the next offset to consume
            offsetsToCommit.put(partition, new OffsetAndMetadata(offset + 1));
        }
        return offsetsToCommit;
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
