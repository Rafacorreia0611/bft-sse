package sse.benchmark;

import sse.metrics.SearchOperationMetrics;
import sse.metrics.UpdateOperationMetrics;

public final class ConcurrentOperationResult {

    private final int clientCount;
    private final int clientId;
    private final long clientOperation;
    private final BenchmarkOperation operation;
    private final String keyword;
    private final int updatedDocumentCount;
    private final long startOffsetNanos;
    private final long totalLatencyNanos;
    private final SearchOperationMetrics searchMetrics;
    private final UpdateOperationMetrics updateMetrics;

    private ConcurrentOperationResult(int clientCount,
                                      int clientId,
                                      long clientOperation,
                                      BenchmarkOperation operation,
                                      String keyword,
                                      int updatedDocumentCount,
                                      long startOffsetNanos,
                                      long totalLatencyNanos,
                                      SearchOperationMetrics searchMetrics,
                                      UpdateOperationMetrics updateMetrics) {
        this.clientCount = clientCount;
        this.clientId = clientId;
        this.clientOperation = clientOperation;
        this.operation = operation;
        this.keyword = keyword;
        this.updatedDocumentCount = updatedDocumentCount;
        this.startOffsetNanos = startOffsetNanos;
        this.totalLatencyNanos = totalLatencyNanos;
        this.searchMetrics = searchMetrics;
        this.updateMetrics = updateMetrics;
    }

    public static ConcurrentOperationResult forSearch(int clientCount,
                                                      int clientId,
                                                      long clientOperation,
                                                      String keyword,
                                                      long startOffsetNanos,
                                                      long totalLatencyNanos,
                                                      SearchOperationMetrics metrics) {
        if (metrics == null) {
            throw new IllegalArgumentException("Search metrics cannot be null");
        }
        return new ConcurrentOperationResult(
                clientCount,
                clientId,
                clientOperation,
                BenchmarkOperation.SEARCH,
                keyword,
                0,
                startOffsetNanos,
                totalLatencyNanos,
                metrics,
                null
        );
    }

    public static ConcurrentOperationResult forUpdate(int clientCount,
                                                      int clientId,
                                                      long clientOperation,
                                                      String keyword,
                                                      int updatedDocumentCount,
                                                      long startOffsetNanos,
                                                      long totalLatencyNanos,
                                                      UpdateOperationMetrics metrics) {
        if (metrics == null) {
            throw new IllegalArgumentException("Update metrics cannot be null");
        }
        return new ConcurrentOperationResult(
                clientCount,
                clientId,
                clientOperation,
                BenchmarkOperation.UPDATE,
                keyword,
                updatedDocumentCount,
                startOffsetNanos,
                totalLatencyNanos,
                null,
                metrics
        );
    }

    public int clientCount() {
        return clientCount;
    }

    public int clientId() {
        return clientId;
    }

    public long clientOperation() {
        return clientOperation;
    }

    public BenchmarkOperation operation() {
        return operation;
    }

    public String keyword() {
        return keyword;
    }

    public int updatedDocumentCount() {
        return updatedDocumentCount;
    }

    public int observedChainLength() {
        if (operation == BenchmarkOperation.SEARCH) {
            return searchMetrics.observedChainLength();
        }
        return updateMetrics.observedChainLengthBefore();
    }

    public long startOffsetNanos() {
        return startOffsetNanos;
    }

    public long totalLatencyNanos() {
        return totalLatencyNanos;
    }

    public SearchOperationMetrics searchMetrics() {
        return searchMetrics;
    }

    public UpdateOperationMetrics updateMetrics() {
        return updateMetrics;
    }
}
