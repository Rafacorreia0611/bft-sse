package sse.metrics;

/**
 * Client-side phase timings for one search operation.
 *
 * <p>Each value is expressed in nanoseconds. A new instance should be used for
 * every measured search.</p>
 */
public final class SearchOperationMetrics {

    private long normalizationLatencyNanos;
    private long stateRequestLatencyNanos;
    private long addressResolutionLatencyNanos;
    private long oramReadLatencyNanos;
    private long tokenBuildLatencyNanos;
    private long searchRequestRoundTripLatencyNanos;
    private long resultProcessingLatencyNanos;

    public long normalizationLatencyNanos() {
        return normalizationLatencyNanos;
    }

    public void recordNormalizationLatency(long latencyNanos) {
        normalizationLatencyNanos = latencyNanos;
    }

    public long stateRequestLatencyNanos() {
        return stateRequestLatencyNanos;
    }

    public void recordStateRequestLatency(long latencyNanos) {
        stateRequestLatencyNanos = latencyNanos;
    }

    public long addressResolutionLatencyNanos() {
        return addressResolutionLatencyNanos;
    }

    public void recordAddressResolutionLatency(long latencyNanos) {
        addressResolutionLatencyNanos = latencyNanos;
    }

    public long oramReadLatencyNanos() {
        return oramReadLatencyNanos;
    }

    public void recordOramReadLatency(long latencyNanos) {
        oramReadLatencyNanos = latencyNanos;
    }

    public long tokenBuildLatencyNanos() {
        return tokenBuildLatencyNanos;
    }

    public void recordTokenBuildLatency(long latencyNanos) {
        tokenBuildLatencyNanos = latencyNanos;
    }

    /**
     * Includes request serialization, communication, BFT execution and reply
     * decoding; it is not a measurement of server processing alone.
     */
    public long searchRequestRoundTripLatencyNanos() {
        return searchRequestRoundTripLatencyNanos;
    }

    public void recordSearchRequestRoundTripLatency(long latencyNanos) {
        searchRequestRoundTripLatencyNanos = latencyNanos;
    }

    public long resultProcessingLatencyNanos() {
        return resultProcessingLatencyNanos;
    }

    public void recordResultProcessingLatency(long latencyNanos) {
        resultProcessingLatencyNanos = latencyNanos;
    }
}
