package sse.benchmark.configs;

import java.nio.file.Path;
import java.util.Properties;

import sse.oram.ORAMSettings;

public final class ConcurrentWorkloadConfig extends BenchmarkConfig {

    private final int clientCount;
    private final int warmupSeconds;
    private final int measurementSeconds;
    private final int warmupKeywordCount;
    private final long seed;

    ConcurrentWorkloadConfig(Properties properties, Path configDirectory) {
        super(properties, configDirectory);
        this.clientCount = requirePositiveInt("clientCount");
        this.warmupSeconds = requirePositiveInt("warmupSeconds");
        this.measurementSeconds = requirePositiveInt("measurementSeconds");
        this.warmupKeywordCount = requirePositiveInt("warmupKeywordCount");
        this.seed = requireLong("seed");

        long highestClientId = (long) clientId() + clientCount - 1L;
        if (highestClientId > Integer.MAX_VALUE - ORAMSettings.DEFAULT_ORAM_CLIENT_ID_OFFSET) {
            throw new IllegalArgumentException("Configured client IDs exceed the supported ORAM client ID range");
        }
    }

    public int clientCount() {
        return clientCount;
    }

    public int warmupSeconds() {
        return warmupSeconds;
    }

    public int measurementSeconds() {
        return measurementSeconds;
    }

    public int warmupKeywordCount() {
        return warmupKeywordCount;
    }

    public long seed() {
        return seed;
    }

    public int clientIdForIndex(int clientIndex) {
        if (clientIndex < 0 || clientIndex >= clientCount) {
            throw new IllegalArgumentException("clientIndex is outside the configured client range");
        }
        return clientId() + clientIndex;
    }
}
