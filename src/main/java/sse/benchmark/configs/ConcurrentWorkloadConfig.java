package sse.benchmark.configs;

import java.nio.file.Path;
import java.util.Properties;

import sse.benchmark.KeywordSelectionDistribution;
import sse.benchmark.LockContentionLevel;
import sse.oram.ORAMSettings;

public final class ConcurrentWorkloadConfig extends BenchmarkConfig {

    private final int clientCount;
    private final int warmupSeconds;
    private final int measurementSeconds;
    private final int warmupKeywordCount;
    private final long seed;
    private final int searchPercentage;
    private final KeywordSelectionDistribution keywordSelectionDistribution;
    private final double zipfianExponent;
    private final LockContentionLevel lockContentionLevel;
    private final int sharedKeywordCount;

    ConcurrentWorkloadConfig(Properties properties, Path configDirectory) {
        super(properties, configDirectory);
        this.clientCount = requirePositiveInt("clientCount");
        this.warmupSeconds = requirePositiveInt("warmupSeconds");
        this.measurementSeconds = requirePositiveInt("measurementSeconds");
        this.warmupKeywordCount = requirePositiveInt("warmupKeywordCount");
        this.seed = requireLong("seed");

        if (isLockContentionScenario()) {
            this.searchPercentage = 0;
            this.keywordSelectionDistribution = KeywordSelectionDistribution.UNIFORM;
            this.zipfianExponent = 0.0;
            this.lockContentionLevel = parseLockContentionLevel(requireProperty("contentionLevel"));
            this.sharedKeywordCount = lockContentionLevel == LockContentionLevel.MODERATE
                    ? requirePositiveInt("sharedKeywordCount")
                    : lockContentionLevel == LockContentionLevel.HIGH ? 1 : 0;
        } else {
            this.searchPercentage = requireNonNegativeInt("searchPercentage");
            if (searchPercentage > 100) {
                throw new IllegalArgumentException("Property searchPercentage must be between 0 and 100");
            }
            this.keywordSelectionDistribution = parseKeywordSelectionDistribution(
                    requireProperty("keywordSelectionDistribution")
            );
            this.zipfianExponent = keywordSelectionDistribution == KeywordSelectionDistribution.ZIPFIAN
                    ? requirePositiveDouble("zipfianExponent")
                    : 0.0;
            this.lockContentionLevel = LockContentionLevel.NONE;
            this.sharedKeywordCount = 0;
        }

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

    public int searchPercentage() {
        return searchPercentage;
    }

    public KeywordSelectionDistribution keywordSelectionDistribution() {
        return keywordSelectionDistribution;
    }

    public double zipfianExponent() {
        return zipfianExponent;
    }

    public boolean isLockContentionScenario() {
        return "lock-contention".equals(scenarioName());
    }

    public LockContentionLevel lockContentionLevel() {
        return lockContentionLevel;
    }

    public int sharedKeywordCount() {
        return sharedKeywordCount;
    }

    public int clientIdForIndex(int clientIndex) {
        if (clientIndex < 0 || clientIndex >= clientCount) {
            throw new IllegalArgumentException("clientIndex is outside the configured client range");
        }
        return clientId() + clientIndex;
    }

    private double requirePositiveDouble(String key) {
        String value = requireProperty(key);
        try {
            double parsed = Double.parseDouble(value);
            if (!Double.isFinite(parsed) || parsed <= 0.0) {
                throw new IllegalArgumentException("Property " + key + " must be a finite number greater than 0");
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Property " + key + " must be a valid number", e);
        }
    }

    private KeywordSelectionDistribution parseKeywordSelectionDistribution(String value) {
        for (KeywordSelectionDistribution distribution : KeywordSelectionDistribution.values()) {
            if (distribution.name().equalsIgnoreCase(value)) {
                return distribution;
            }
        }
        throw new IllegalArgumentException(
                "Property keywordSelectionDistribution must be uniform or zipfian"
        );
    }

    private LockContentionLevel parseLockContentionLevel(String value) {
        for (LockContentionLevel level : LockContentionLevel.values()) {
            if (level.name().equalsIgnoreCase(value)) {
                return level;
            }
        }
        throw new IllegalArgumentException(
                "Property contentionLevel must be none, moderate or high"
        );
    }
}
