package sse.benchmark;

import sse.benchmark.scenario.SearchLatencyByDocsScenario;
import sse.benchmark.scenario.UpdateLatencyByAssociationsScenario;

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
        String scenarioName = config.scenarioName();
        if ("search-latency-by-docs".equals(scenarioName)) {
            return new SearchLatencyByDocsScenario();
        }
        if ("update-latency-by-associations".equals(scenarioName)) {
            return new UpdateLatencyByAssociationsScenario();
        }

        throw new IllegalArgumentException("Unknown benchmark scenario: " + scenarioName);
    }
}
