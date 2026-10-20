package sse.benchmark;

import sse.metrics.SearchOperationMetrics;

public final class ConcurrentOperationResult {

    private final int clientCount;
    private final int clientId;
    private final long clientOperation;
    private final String keyword;
    private final int resultCount;
    private final long startOffsetNanos;
    private final long totalLatencyNanos;
    private final SearchOperationMetrics metrics;

    public ConcurrentOperationResult(int clientCount,
                                     int clientId,
                                     long clientOperation,
                                     String keyword,
                                     int resultCount,
                                     long startOffsetNanos,
                                     long totalLatencyNanos,
                                     SearchOperationMetrics metrics) {
        this.clientCount = clientCount;
        this.clientId = clientId;
        this.clientOperation = clientOperation;
        this.keyword = keyword;
        this.resultCount = resultCount;
        this.startOffsetNanos = startOffsetNanos;
        this.totalLatencyNanos = totalLatencyNanos;
        this.metrics = metrics;
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

    public String keyword() {
        return keyword;
    }

    public int resultCount() {
        return resultCount;
    }

    public long startOffsetNanos() {
        return startOffsetNanos;
    }

    public long totalLatencyNanos() {
        return totalLatencyNanos;
    }

    public SearchOperationMetrics metrics() {
        return metrics;
    }
}
