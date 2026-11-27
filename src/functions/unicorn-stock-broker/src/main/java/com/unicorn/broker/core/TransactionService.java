package com.unicorn.broker.core;

import com.unicorn.broker.data.TransactionRepository;
import com.unicorn.broker.model.Transaction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Optional;
import java.util.UUID;

/**
 * Domain service for the Unicorn Stock Broker function.
 *
 * <p>The business logic implements the following behavior and timing semantics:</p>
 * <ul>
 *     <li>100 ms simulated calculation</li>
 *     <li>A per-instance {@code BROKER_ID} (captured on first construction)</li>
 *     <li>A new {@code transactionId} generated per request</li>
 * </ul>
 */
public class TransactionService {

    private static final Logger logger = LoggerFactory.getLogger(TransactionService.class);

    private final UUID brokerId = UUID.randomUUID();
    private final TransactionRepository transactionRepository;

    public TransactionService(TransactionRepository transactionRepository) {
        this.transactionRepository = transactionRepository;
    }

    public Optional<Transaction> writeTransaction(Transaction transaction) {
        try {
            Thread.sleep(100); //Simulates some intensive calculation
            transaction.transactionId = UUID.randomUUID();
            transaction.brokerId = brokerId;

            return transactionRepository.writeTransaction(transaction);
        } catch (InterruptedException e) {
            logger.error("Error due to interruption while processing the transaction.", e);
            return Optional.empty();
        }
    }
}