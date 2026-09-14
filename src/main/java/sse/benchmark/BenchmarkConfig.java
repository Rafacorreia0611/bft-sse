package sse.benchmark;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Properties;

public final class BenchmarkConfig {

    private final String scenarioName;
    private final int clientId;
    private final int warmupIterations;
    private final int measurementIterations;
    private final String outputPath;
    private final String inputPath;
    private final String vocabularyPath;
    private final List<BenchmarkBucket> buckets;

    private BenchmarkConfig(String scenarioName,
                            int clientId,
                            int warmupIterations,
                            int measurementIterations,
                            String outputPath,
                            String inputPath,
                            String vocabularyPath,
                            List<BenchmarkBucket> buckets) {
        this.scenarioName = scenarioName;
        this.clientId = clientId;
        this.warmupIterations = warmupIterations;
        this.measurementIterations = measurementIterations;
        this.outputPath = outputPath;
        this.inputPath = inputPath;
        this.vocabularyPath = vocabularyPath;
        this.buckets = new ArrayList<BenchmarkBucket>(buckets);
    }

    public String scenarioName() {
        return scenarioName;
    }

    public int clientId() {
        return clientId;
    }

    public int warmupIterations() {
        return warmupIterations;
    }

    public int measurementIterations() {
        return measurementIterations;
    }

    public String outputPath() {
        return outputPath;
    }

    public String inputPath() {
        return inputPath;
    }

    public String vocabularyPath() {
        return vocabularyPath;
    }

    public List<BenchmarkBucket> buckets() {
        return new ArrayList<BenchmarkBucket>(buckets);
    }

    public static BenchmarkConfig fromArgs(String[] args) {
        Path configPath = parseConfigPath(args);
        Properties properties = loadProperties(configPath);
        Path configDirectory = configPath.toAbsolutePath().getParent();

        String scenarioName = requireProperty(properties, "scenario");
        int clientId = parsePositiveInt(properties, "clientId");
        String outputPath = resolvePath(configDirectory, requireProperty(properties, "outputPath"));
        String inputPath = resolvePath(configDirectory, requireProperty(properties, "inputPath"));

        if ("search-latency-by-docs".equals(scenarioName)) {
            int warmupIterations = parseNonNegativeInt(properties, "warmupPerBucket");
            int measurementIterations = parsePositiveInt(properties, "measurementsPerBucket");
            String vocabularyPath = resolvePath(
                    configDirectory,
                    requireProperty(properties, "vocabularyPath")
            );
            List<BenchmarkBucket> buckets = parseBuckets(requireProperty(properties, "buckets"));

            return new BenchmarkConfig(
                    scenarioName,
                    clientId,
                    warmupIterations,
                    measurementIterations,
                    outputPath,
                    inputPath,
                    vocabularyPath,
                    buckets
            );
        }

        if ("update-latency-by-associations".equals(scenarioName)) {
            int warmupIterations = parseNonNegativeInt(properties, "warmupPayloadCount");

            return new BenchmarkConfig(
                    scenarioName,
                    clientId,
                    warmupIterations,
                    1,
                    outputPath,
                    inputPath,
                    null,
                    Collections.<BenchmarkBucket>emptyList()
            );
        }

        throw new IllegalArgumentException("Unknown benchmark scenario: " + scenarioName);
    }

    private static Path parseConfigPath(String[] args) {
        if (args.length == 1 && args[0] != null && !args[0].trim().isEmpty() && !args[0].startsWith("--")) {
            return Paths.get(args[0]);
        }
        if (args.length == 1 && args[0] != null && args[0].startsWith("--config=")) {
            return Paths.get(args[0].substring("--config=".length()));
        }
        throw new IllegalArgumentException("Usage: BenchmarkClient <configPath> or --config=<configPath>");
    }

    private static Properties loadProperties(Path configPath) {
        if (configPath == null) {
            throw new IllegalArgumentException("configPath cannot be null");
        }
        if (!Files.exists(configPath) || !Files.isRegularFile(configPath)) {
            throw new IllegalArgumentException("Benchmark config file does not exist: " + configPath.toAbsolutePath());
        }

        Properties properties = new Properties();
        try (InputStream in = Files.newInputStream(configPath)) {
            properties.load(in);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to read benchmark config " + configPath.toAbsolutePath(), e);
        }
        return properties;
    }

    private static String resolvePath(Path configDirectory, String rawPath) {
        Path path = Paths.get(rawPath);
        if (path.isAbsolute()) {
            return path.normalize().toString();
        }

        Path baseDirectory = configDirectory == null ? Paths.get("").toAbsolutePath() : configDirectory;
        return baseDirectory.resolve(path).normalize().toString();
    }

    private static String requireProperty(Properties properties, String key) {
        String value = properties.getProperty(key);
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException("Missing required benchmark config property: " + key);
        }
        return value.trim();
    }

    private static int parsePositiveInt(Properties properties, String key) {
        int value = parseInt(properties, key);
        if (value <= 0) {
            throw new IllegalArgumentException("Property " + key + " must be greater than 0");
        }
        return value;
    }

    private static int parseNonNegativeInt(Properties properties, String key) {
        int value = parseInt(properties, key);
        if (value < 0) {
            throw new IllegalArgumentException("Property " + key + " must be 0 or greater");
        }
        return value;
    }

    private static int parseInt(Properties properties, String key) {
        String value = requireProperty(properties, key);
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Property " + key + " must be a valid integer", e);
        }
    }

    private static List<BenchmarkBucket> parseBuckets(String bucketSpec) {
        String[] rawBuckets = bucketSpec.split(",");
        List<BenchmarkBucket> buckets = new ArrayList<BenchmarkBucket>(rawBuckets.length);
        for (String rawBucket : rawBuckets) {
            String normalized = rawBucket.trim();
            if (normalized.isEmpty()) {
                throw new IllegalArgumentException("Bucket config cannot contain empty definitions");
            }

            int separatorIndex = normalized.indexOf(':');
            if (separatorIndex <= 0 || separatorIndex == normalized.length() - 1
                    || normalized.indexOf(':', separatorIndex + 1) >= 0) {
                throw new IllegalArgumentException("Invalid bucket definition: " + normalized);
            }

            int minDocs = parsePositiveIntValue(normalized.substring(0, separatorIndex), "bucket min");
            int maxDocs = parsePositiveIntValue(normalized.substring(separatorIndex + 1), "bucket max");
            BenchmarkBucket bucket = new BenchmarkBucket(minDocs, maxDocs);
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

    private static int parsePositiveIntValue(String value, String label) {
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
