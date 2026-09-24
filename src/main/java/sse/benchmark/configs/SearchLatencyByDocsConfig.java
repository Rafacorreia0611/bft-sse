package sse.benchmark.configs;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;

import sse.benchmark.BenchmarkBucket;

public final class SearchLatencyByDocsConfig extends BenchmarkConfig {

    private final int warmupPerBucket;
    private final int measurementsPerBucket;
    private final List<BenchmarkBucket> buckets;

    SearchLatencyByDocsConfig(Properties properties, Path configDirectory) {
        super(properties, configDirectory);
        this.warmupPerBucket = requireNonNegativeInt("warmupPerBucket");
        this.measurementsPerBucket = requirePositiveInt("measurementsPerBucket");
        this.buckets = parseBuckets(requireProperty("buckets"));
    }

    public int warmupPerBucket() {
        return warmupPerBucket;
    }

    public int measurementsPerBucket() {
        return measurementsPerBucket;
    }

    public List<BenchmarkBucket> buckets() {
        return new ArrayList<BenchmarkBucket>(buckets);
    }

    private static List<BenchmarkBucket> parseBuckets(String bucketSpec) {
        String[] rawBuckets = bucketSpec.split(",");
        List<BenchmarkBucket> buckets = new ArrayList<BenchmarkBucket>(rawBuckets.length);
        for (String rawBucket : rawBuckets) {
            String normalized = rawBucket.trim();
            int separatorIndex = normalized.indexOf(':');
            if (separatorIndex <= 0 || separatorIndex == normalized.length() - 1
                    || normalized.indexOf(':', separatorIndex + 1) >= 0) {
                throw new IllegalArgumentException("Invalid bucket definition: " + normalized);
            }

            BenchmarkBucket bucket = new BenchmarkBucket(
                    parsePositiveInt(normalized.substring(0, separatorIndex), "bucket min"),
                    parsePositiveInt(normalized.substring(separatorIndex + 1), "bucket max")
            );
            for (BenchmarkBucket existing : buckets) {
                if (existing.overlaps(bucket)) {
                    throw new IllegalArgumentException("Overlapping benchmark buckets are not allowed: "
                            + existing.label() + " and " + bucket.label());
                }
            }
            buckets.add(bucket);
        }
        return buckets;
    }

    private static int parsePositiveInt(String value, String label) {
        try {
            int parsed = Integer.parseInt(value.trim());
            if (parsed <= 0) {
                throw new IllegalArgumentException(label + " must be greater than 0");
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(label + " must be a valid integer: " + value, e);
        }
    }
}
