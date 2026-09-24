package sse.benchmark.configs;

import java.nio.file.Path;
import java.util.Properties;

public final class UpdateLatencyByDocsConfig extends BenchmarkConfig {

    private final int warmupCount;
    private final int measurementCount;
    private final int measurementDocCount;
    private final long dbSize;
    private final long initialDbSize;

    UpdateLatencyByDocsConfig(Properties properties, Path configDirectory) {
        super(properties, configDirectory);

        int warmupCount = requireNonNegativeInt("warmupCount");
        int measurementCount = requirePositiveInt("measurementCount");
        int measurementDocCount = requirePositiveInt("measurementDocCount");
        long dbSize = requirePositiveLong("dbSize");
        if (measurementCount % 2 == 0) {
            throw new IllegalArgumentException("measurementCount must be odd");
        }

        long updatesBeforeFirstMeasurement = warmupCount + measurementCount / 2;
        long calculatedInitialDbSize = dbSize - updatesBeforeFirstMeasurement * measurementDocCount;
        if (calculatedInitialDbSize <= 0L) {
            throw new IllegalArgumentException(
                    "dbSize is too small for the configured warm-ups and measurements"
            );
        }

        this.warmupCount = warmupCount;
        this.measurementCount = measurementCount;
        this.measurementDocCount = measurementDocCount;
        this.dbSize = dbSize;
        this.initialDbSize = calculatedInitialDbSize;
    }

    public int warmupCount() {
        return warmupCount;
    }

    public int measurementCount() {
        return measurementCount;
    }

    public int measurementDocCount() {
        return measurementDocCount;
    }

    public long dbSize() {
        return dbSize;
    }

    public long initialDbSize() {
        return initialDbSize;
    }

    public long expectedDbSizeBefore(int measurementIndex) {
        if (measurementIndex < 0 || measurementIndex >= measurementCount) {
            throw new IllegalArgumentException("measurementIndex is outside the configured measurement range");
        }
        long centeredIndex = measurementIndex - measurementCount / 2;
        return dbSize + centeredIndex * measurementDocCount;
    }
}
