package com.unicorn.broker.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import java.util.UUID;

/**
 * Transaction payload accepted by the Unicorn Stock Broker FunctionGraph function.
 *
 * <p>The payload shape is defined as follows. The validation rules and
 * wide-table item mapping are defined accordingly. No platform-specific types are used.</p>
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Transaction {
    public String stockId;
    public Integer quantity;
    public UUID brokerId;
    public UUID transactionId;

    public Boolean isValid() {
        return (stockId != null && !stockId.isBlank() && quantity != null && quantity > 0);
    }
}