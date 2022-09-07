package it.fvaleri.example;

import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.KafkaException;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
import org.apache.kafka.common.errors.OutOfOrderSequenceException;
import org.apache.kafka.common.errors.ProducerFencedException;
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
    private static final String BOOTSTRAP_SERVERS = "localhost:9092";
    private static final String TRANSACTIONAL_ID = "my-unique-static-tid";
    private static final String GROUP_ID = "my-group";
    private static final String INPUT_TOPIC = "wc-input";
    private static final int INPUT_PARTITION = 0;
    private static final String OUTPUT_TOPIC = "wc-output";
    private static boolean CLOSED = false;

    public static void main(String[] args) {
        try (var producer = createKafkaProducer();
             var consumer = createKafkaConsumer()) {
            // transaction APIs are all blocking with a max.block.ms timeout
            // called once to register the transactional.id, abort any pending TX, and get a new session (pid+epoch)
            producer.initTransactions();

            while (!CLOSED) {
                try {
                    System.out.println("READ: Waiting for new user sentence");
                    ConsumerRecords<String, String> consumerRecords = consumer.poll(ofSeconds(60));

                    if (!consumerRecords.isEmpty()) {
                        producer.beginTransaction();
                        System.out.println("PROCESS: Computing word counts");
                        Map<String, Integer> wordCountMap =
                            consumerRecords.records(new TopicPartition(INPUT_TOPIC, INPUT_PARTITION))
                                .stream()
                                .flatMap(record -> Stream.of(record.value().split(" ")))
                                .map(word -> Tuple.of(word, 1))
                                .collect(Collectors.toMap(tuple -> tuple.getKey(), t1 -> t1.getValue(), (v1, v2) -> v1 + v2));

                        System.out.println("WRITE: Sending offsets and counts atomically");
                        wordCountMap.forEach((key, value) -> producer.send(new ProducerRecord<String, String>(OUTPUT_TOPIC, key, value.toString())));
                        // notifies the coordinator about consumed offsets, which should be committed at the same time as the transaction
                        producer.sendOffsetsToTransaction(getOffsetsToCommit(consumerRecords), consumer.groupMetadata());
                        producer.commitTransaction();
                    }
                } catch (ProducerFencedException | OutOfOrderSequenceException | AuthorizationException e) {
                    // we can't recover from these exceptions
                    CLOSED = true;
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

    private static KafkaProducer<String, String> createKafkaProducer() {
        System.out.println("Creating a new transactional producer");
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        // the transactional id must be unique and not change across restarts
        props.put(ProducerConfig.TRANSACTIONAL_ID_CONFIG, TRANSACTIONAL_ID);
        props.put(ProducerConfig.TRANSACTION_TIMEOUT_CONFIG, 60_000);
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        return new KafkaProducer(props);
    }

    private static KafkaConsumer<String, String> createKafkaConsumer() {
        System.out.println("Creating a new transaction-aware consumer");
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        // fetch all but ignore records from ongoing and aborted transactions
        props.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
        props.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP_ID);
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
        consumer.subscribe(singleton(INPUT_TOPIC));
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
