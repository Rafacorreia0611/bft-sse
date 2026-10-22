package sse.benchmark;

import sse.benchmark.configs.BenchmarkConfig;
import sse.benchmark.configs.ConcurrentWorkloadConfig;
import sse.benchmark.configs.SearchLatencyByDocsConfig;
import sse.benchmark.configs.UpdateLatencyByDocsConfig;
import sse.benchmark.scenario.ConcurrentWorkloadScenario;
import sse.benchmark.scenario.SearchLatencyByDocsScenario;
import sse.benchmark.scenario.UpdateLatencyByDocsScenario;

public final class BenchmarkClient {

    private BenchmarkClient() {
    }

    public static void main(String[] args) throws Exception {
        BenchmarkConfig config = BenchmarkConfig.fromArgs(args);
        BenchmarkScenario scenario = selectScenario(config);
        long startTime = System.nanoTime();

        System.out.println("Starting benchmark scenario: " + scenario.name());
        try (BenchmarkResultWriter resultWriter = new BenchmarkResultWriter(config.outputPath())) {
            scenario.writeHeader(resultWriter);
            scenario.run(config, resultWriter);
        }
        long elapsedMillis = (System.nanoTime() - startTime) / 1_000_000L;
        System.out.println("Benchmark finished successfully in " + elapsedMillis + " ms.");
        System.out.println("Results written to: " + config.outputPath());
    }

    static BenchmarkScenario selectScenario(BenchmarkConfig config) {
        if (config instanceof SearchLatencyByDocsConfig) {
            return new SearchLatencyByDocsScenario();
        }
        if (config instanceof UpdateLatencyByDocsConfig) {
            return new UpdateLatencyByDocsScenario();
        }
        if (config instanceof ConcurrentWorkloadConfig) {
            return new ConcurrentWorkloadScenario(config.scenarioName());
        }

        throw new IllegalArgumentException("Unsupported benchmark config: " + config.getClass().getName());
    }
}
