package sse.metrics;

/**
 * Client-side phase timings for one update operation.
 *
 * <p>Each value is expressed in nanoseconds. A new instance should be used for
 * every measured update.</p>
 */
public final class UpdateOperationMetrics {

    private long normalizationLatencyNanos;
    private long stateRequestLatencyNanos;
    private long addressResolutionLatencyNanos;
    private long oramLockLatencyNanos;
    private int oramLockRetryCount;
    private long tokenBuildLatencyNanos;
    private long updateRequestRoundTripLatencyNanos;
    private long oramPublishLatencyNanos;
    private int observedChainLengthBefore;

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

    /**
     * Includes all ORAM lock attempts and retry delays until the lock is
     * acquired.
     */
    public long oramLockLatencyNanos() {
        return oramLockLatencyNanos;
    }

    public void recordOramLockLatency(long latencyNanos) {
        oramLockLatencyNanos = latencyNanos;
    }

    public int oramLockRetryCount() {
        return oramLockRetryCount;
    }

    public void recordOramLockRetryCount(int retryCount) {
        if (retryCount < 0) {
            throw new IllegalArgumentException("ORAM lock retry count cannot be negative");
        }
        oramLockRetryCount = retryCount;
    }

    public long tokenBuildLatencyNanos() {
        return tokenBuildLatencyNanos;
    }

    public void recordTokenBuildLatency(long latencyNanos) {
        tokenBuildLatencyNanos = latencyNanos;
    }

    /**
     * Includes request serialization, confidential-data processing,
     * communication, BFT execution and reply decoding; it is not a
     * measurement of server processing alone.
     */
    public long updateRequestRoundTripLatencyNanos() {
        return updateRequestRoundTripLatencyNanos;
    }

    public void recordUpdateRequestRoundTripLatency(long latencyNanos) {
        updateRequestRoundTripLatencyNanos = latencyNanos;
    }

    /**
     * Covers publishing the committed keyword state to ORAM, which also
     * releases the keyword lock.
     */
    public long oramPublishLatencyNanos() {
        return oramPublishLatencyNanos;
    }

    public void recordOramPublishLatency(long latencyNanos) {
        oramPublishLatencyNanos = latencyNanos;
    }

    public int observedChainLengthBefore() {
        return observedChainLengthBefore;
    }

    public void recordObservedChainLengthBefore(int chainLength) {
        observedChainLengthBefore = chainLength;
    }
}
