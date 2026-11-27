package com.unicorn.broker.data;

import com.unicorn.broker.model.Transaction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeDefinition;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.BillingMode;
import software.amazon.awssdk.services.dynamodb.model.CreateTableRequest;
import software.amazon.awssdk.services.dynamodb.model.DescribeTableRequest;
import software.amazon.awssdk.services.dynamodb.model.KeySchemaElement;
import software.amazon.awssdk.services.dynamodb.model.KeyType;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemResponse;
import software.amazon.awssdk.services.dynamodb.model.ResourceNotFoundException;
import software.amazon.awssdk.services.dynamodb.model.ScalarAttributeType;
import software.amazon.awssdk.services.dynamodb.waiters.DynamoDbWaiter;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Repository writing Transactions to GeminiDB (DynamoDB-compatible).
 *
 * <p><b>Credential model (critical):</b> the DynamoDB-compatible data plane of
 * GeminiDB authenticates against the <i>instance's own database account</i> —
 * the fixed administrator user {@code rwuser} plus the instance administrator
 * password. It does <b>not</b> accept Huawei Cloud IAM AK/SK, and it does
 * <b>not</b> support a security token. Those two values are supplied as
 * environment variables ({@code GEMINIDB_USER} / {@code GEMINIDB_PASSWORD})
 * injected by Terraform; the temporary credentials carried by the
 * FunctionGraph execution context are deliberately not used here.</p>
 *
    * <p>{@code region} is used only to build the SigV4 signature. Routing is
     * determined solely by {@code endpoint}, which is the instance load-balancer
     * address on port 80 (the DynamoDB-compatible LB VIP port; 8000 is the
     * data-node port and must not be used from clients).</p>
 *
 * <p>Uses the synchronous {@link DynamoDbClient} with the SDK's default sync
 * HTTP client: a request-driven handler needs no async client, and the default
 * client keeps the shaded jar small.</p>
 */
public class TransactionRepository {

    private static final Logger logger = LoggerFactory.getLogger(TransactionRepository.class);

    private final DynamoDbClient dynamoDbClient;
    private final String tableName;

    public TransactionRepository(String endpoint, String region, String user,
                                 String password, String tableName) {
        this.tableName = tableName;

        // Static credentials: GeminiDB's DynamoDB-compatible data plane only
        // understands the instance database account (rwuser + admin password).
        // The synchronous DynamoDbClient uses the SDK's default sync HTTP client
        // (url-connection-client), which is already on the classpath via the
        // dynamodb artifact — no extra HTTP client dependency is needed.
        this.dynamoDbClient = DynamoDbClient.builder()
                .region(Region.of(region))
                .endpointOverride(java.net.URI.create(endpoint))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(user, password)))
                .build();

        createTableIfNotExists();
    }

    /**
     * Idempotently ensures {@code TransactionsTable} exists on the GeminiDB
     * DynamoDB-compatible endpoint. GeminiDB does not auto-create tables on
     * first write, so the first {@code putItem}
     * otherwise fails with {@code ResourceNotFoundException}.
     *
     * <p>Schema: HASH key {@code transactionId} (String), on-demand billing.
     * Runs once per cold start (constructor) — {@code describeTable} makes
     * warm invocations skip the create path entirely.</p>
     */
    private void createTableIfNotExists() {
        try {
            dynamoDbClient.describeTable(DescribeTableRequest.builder()
                    .tableName(tableName)
                    .build());
            logger.info("Table {} already exists", tableName);
        } catch (ResourceNotFoundException e) {
            logger.info("Table {} not found — creating it", tableName);
            dynamoDbClient.createTable(CreateTableRequest.builder()
                    .tableName(tableName)
                    .attributeDefinitions(AttributeDefinition.builder()
                            .attributeName("transactionId")
                            .attributeType(ScalarAttributeType.S)
                            .build())
                    .keySchema(KeySchemaElement.builder()
                            .attributeName("transactionId")
                            .keyType(KeyType.HASH)
                            .build())
                    // NOTE: GeminiDB's DynamoDB-compatible layer does NOT accept
                    // BillingMode.PAY_PER_REQUEST ("No provisioned throughput
                    // specified"). Provisioned values are protocol-compliance
                    // only — GeminiDB bills per instance, not per RCU/WCU.
                    .provisionedThroughput(software.amazon.awssdk.services.dynamodb.model.ProvisionedThroughput.builder()
                            .readCapacityUnits(5L)
                            .writeCapacityUnits(5L)
                            .build())
                    .build());
            // Block until the table is ACTIVE so the first putItem cannot race it.
            try (DynamoDbWaiter waiter = dynamoDbClient.waiter()) {
                waiter.waitUntilTableExists(DescribeTableRequest.builder()
                        .tableName(tableName)
                        .build());
            }
            logger.info("Table {} created and active", tableName);
        } catch (Exception e) {
            System.out.println("GEMINIDB_TABLE_CHECK_ERROR: " + e.getClass().getSimpleName()
                    + " - " + e.getMessage());
            throw e;
        }
    }

    public Optional<Transaction> writeTransaction(Transaction transaction) {
        try {
            PutItemResponse response = dynamoDbClient.putItem(PutItemRequest.builder()
                    .tableName(tableName)
                    .item(createTransactionDBItem(transaction))
                    .build());

            logger.info("PutItem response metadata: {}", response.sdkHttpResponse().statusCode());
            return Optional.of(transaction);
        } catch (Exception e) {
            logger.error("Error while writing transaction to GeminiDB (DynamoDB-compatible)", e);
            // Print a short, non-stack-traced line to stdout so the FGS tail log
            // cannot truncate away the actual exception message.
            System.out.println("GEMINIDB_ERROR: " + e.getClass().getSimpleName()
                    + " - " + e.getMessage());
            return Optional.empty();
        }
    }

    private static Map<String, AttributeValue> createTransactionDBItem(Transaction transaction) {
        Map<String, AttributeValue> item = new HashMap<>();

        item.put("transactionId", AttributeValue.builder().s(transaction.transactionId.toString()).build());
        item.put("stock", AttributeValue.builder().s(transaction.stockId).build());
        item.put("quantity", AttributeValue.builder().n(transaction.quantity.toString()).build());
        item.put("broker_id", AttributeValue.builder().s(transaction.brokerId.toString()).build());

        return item;
    }
}