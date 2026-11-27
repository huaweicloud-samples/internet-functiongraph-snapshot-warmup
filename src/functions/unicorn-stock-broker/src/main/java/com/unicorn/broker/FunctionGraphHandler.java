package com.unicorn.broker;

import com.huawei.services.runtime.Context;
import com.unicorn.broker.core.UnicornStockBrokerHandler;

import java.util.Map;

/**
 * FunctionGraph entry point.
 *
 * <p>The handler string configured in Terraform is
 * {@code com.unicorn.broker.FunctionGraphHandler::handleRequest}. The runtime
 * invokes it once per request, passing the APIG proxy event as the first
 * argument and the runtime {@link Context} as the second.</p>
 *
 * <p>The {@link Context} parameter is present to match the FunctionGraph Java
 * handler signature, but it is deliberately <b>not</b> used to obtain
 * credentials: GeminiDB's DynamoDB-compatible data plane authenticates with
 * the instance database account ({@code rwuser} plus the instance
 * administrator password) supplied through environment variables, and does
 * not accept IAM-derived temporary keys.</p>
 */
public class FunctionGraphHandler {

    // Two-argument handler — FunctionGraph Java runtime requires the second
    // parameter to be com.huawei.services.runtime.Context (supplied by the
    // fss-java-sdk provided to the runtime, not bundled in this jar). The
    // Context param is intentionally unused: GeminiDB authenticates via env
    // vars (rwuser + instance admin password), not via the IAM agency AK/SK.
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        UnicornStockBrokerHandler delegate = UnicornStockBrokerHandler.fromEnv();
        return delegate.handle(event);
    }
}