package com.unicorn.broker.core;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.unicorn.broker.data.TransactionRepository;
import com.unicorn.broker.model.Transaction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * FunctionGraph handler for the Unicorn Stock Broker transaction API.
 *
 * <p>Adapts the transaction-write business logic to the FunctionGraph
 * programming model:</p>
 *
 * <ul>
 *   <li>Returns a {@code Map<String,Object>} that the APIG proxy integration
 *       serialises to {@code {"statusCode":.., "body":.., "headers":..,
 *       "isBase64Encoded":..}}.</li>
 *   <li>The {@code TransactionRepository} is built from the GeminiDB instance
 *       database account ({@code GEMINIDB_USER} / {@code GEMINIDB_PASSWORD})
 *       injected as environment variables. No credentials are baked into the
 *       jar.</li>
 * </ul>
 *
 * <p>Validation, business logic and item shape are unchanged.</p>
 */
public class UnicornStockBrokerHandler {

    private static final Logger logger = LoggerFactory.getLogger(UnicornStockBrokerHandler.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int END_OF_FIRST_UUID_GROUP = 8;

    private final TransactionService transactionService;

    public UnicornStockBrokerHandler(TransactionService transactionService) {
        this.transactionService = transactionService;
    }

    /**
     * Builds the handler from the environment variables injected by Terraform
     * (see {@code infra/functiongraph.tf}, {@code user_data}).
     *
     * <p>GeminiDB's DynamoDB-compatible data plane authenticates with the
     * instance database account, so {@code GEMINIDB_USER} is the fixed
     * administrator {@code rwuser} and {@code GEMINIDB_PASSWORD} is the
     * instance administrator password.</p>
     */
    public static UnicornStockBrokerHandler fromEnv() {
        String tableName = System.getenv("TABLE_NAME");
        String endpoint = System.getenv("GEMINIDB_ENDPOINT");
        String region = System.getenv("REGION");
        String user = System.getenv("GEMINIDB_USER");
        String password = System.getenv("GEMINIDB_PASSWORD");

        TransactionRepository repository = new TransactionRepository(
                endpoint, region, user, password, tableName);
        TransactionService service = new TransactionService(repository);
        return new UnicornStockBrokerHandler(service);
    }

    public Map<String, Object> handle(Map<String, Object> event) {
        try {
            Map<String, Object> body = extractBody(event);
            Transaction transaction = MAPPER.convertValue(body, Transaction.class);

            if (transaction == null || !Boolean.TRUE.equals(transaction.isValid())) {
                return createResponse(400, "Invalid request body.");
            }

            return transactionService.writeTransaction(transaction)
                    .map(t -> createResponse(200, generateJSONResponse(t)))
                    .orElseGet(() -> createResponse(500, "Unexpected error while writing transaction. Check GEMINIDB_ERROR in FGS log."));
        } catch (Exception e) {
            logger.error("Error processing event", e);
            return createResponse(500, "Internal error: " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    /**
     * The APIG proxy integration forwards requests using the standard proxy
     * payload format. When the body is already a parsed map we use it directly;
     * when it's a raw string we parse it.
     */
    @SuppressWarnings("unchecked")
    private Map<String, Object> extractBody(Map<String, Object> event) {
        if (event == null) {
            return Map.of();
        }
        Object body = event.get("body");
        if (body instanceof Map) {
            return (Map<String, Object>) body;
        }
        if (body instanceof String) {
            String s = (String) body;
            if (!s.isBlank()) {
                try {
                    return MAPPER.readValue(s, Map.class);
                } catch (JsonProcessingException e) {
                    logger.warn("Request body is not valid JSON", e);
                    return Map.of();
                }
            }
        }
        // Some FunctionGraph triggers forward the entire APIG proxy event;
        // already-parsed payload goes straight through.
        return event;
    }

    private Map<String, Object> createResponse(int statusCode, String message) {
        Map<String, Object> response = new LinkedHashMap<>();
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", "application/json");
        response.put("statusCode", statusCode);
        response.put("headers", headers);
        response.put("isBase64Encoded", false);
        response.put("body", String.format("%s%n", message));
        return response;
    }

    private String generateJSONResponse(Transaction transaction) {
        return String.format("Broker %s successfully created transaction %s",
                transaction.brokerId.toString().substring(0, END_OF_FIRST_UUID_GROUP),
                transaction.transactionId);
    }
}