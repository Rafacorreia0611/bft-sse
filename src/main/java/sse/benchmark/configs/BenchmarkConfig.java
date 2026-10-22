package sse.benchmark.configs;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

public abstract class BenchmarkConfig {

    private final Properties properties;
    private final Path configDirectory;
    private final String scenarioName;
    private final int clientId;
    private final String inputPath;
    private final String outputPath;
    private final String vocabularyPath;

    protected BenchmarkConfig(Properties properties, Path configDirectory) {
        this.properties = properties;
        this.configDirectory = configDirectory;
        this.scenarioName = requireProperty("scenario");
        this.clientId = requirePositiveInt("clientId");
        this.inputPath = requireResolvedPath("inputPath");
        this.outputPath = requireResolvedPath("outputPath");
        this.vocabularyPath = requireResolvedPath("vocabularyPath");
    }

    public String scenarioName() {
        return scenarioName;
    }

    public int clientId() {
        return clientId;
    }

    public String inputPath() {
        return inputPath;
    }

    public String outputPath() {
        return outputPath;
    }

    public String vocabularyPath() {
        return vocabularyPath;
    }

    protected final String requireProperty(String key) {
        String value = properties.getProperty(key);
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException("Missing required benchmark config property: " + key);
        }
        return value.trim();
    }

    protected final int requirePositiveInt(String key) {
        int value = requireInt(key);
        if (value <= 0) {
            throw new IllegalArgumentException("Property " + key + " must be greater than 0");
        }
        return value;
    }

    protected final int requireNonNegativeInt(String key) {
        int value = requireInt(key);
        if (value < 0) {
            throw new IllegalArgumentException("Property " + key + " must be 0 or greater");
        }
        return value;
    }

    protected final long requirePositiveLong(String key) {
        long parsed = requireLong(key);
        if (parsed <= 0L) {
            throw new IllegalArgumentException("Property " + key + " must be greater than 0");
        }
        return parsed;
    }

    protected final long requireLong(String key) {
        String value = requireProperty(key);
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Property " + key + " must be a valid long", e);
        }
    }

    public static BenchmarkConfig fromArgs(String[] args) {
        Path configPath = parseConfigPath(args).toAbsolutePath().normalize();
        Properties properties = loadProperties(configPath);
        Path configDirectory = configPath.getParent();
        String scenarioName = requireProperty(properties, "scenario");

        if ("search-latency-by-docs".equals(scenarioName)) {
            return new SearchLatencyByDocsConfig(properties, configDirectory);
        }
        if ("update-latency-by-docs".equals(scenarioName)) {
            return new UpdateLatencyByDocsConfig(properties, configDirectory);
        }
        if ("concurrent-workload".equals(scenarioName)
                || "lock-contention".equals(scenarioName)) {
            return new ConcurrentWorkloadConfig(properties, configDirectory);
        }
        throw new IllegalArgumentException("Unknown benchmark scenario: " + scenarioName);
    }

    private int requireInt(String key) {
        String value = requireProperty(key);
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Property " + key + " must be a valid integer", e);
        }
    }

    private String requireResolvedPath(String key) {
        Path path = Paths.get(requireProperty(key));
        if (path.isAbsolute()) {
            return path.normalize().toString();
        }
        return configDirectory.resolve(path).normalize().toString();
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
        if (!Files.exists(configPath) || !Files.isRegularFile(configPath)) {
            throw new IllegalArgumentException("Benchmark config file does not exist: " + configPath);
        }

        Properties properties = new Properties();
        try (InputStream in = Files.newInputStream(configPath)) {
            properties.load(in);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to read benchmark config " + configPath, e);
        }
        return properties;
    }

    private static String requireProperty(Properties properties, String key) {
        String value = properties.getProperty(key);
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException("Missing required benchmark config property: " + key);
        }
        return value.trim();
    }
}
