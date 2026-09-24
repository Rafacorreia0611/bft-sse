package sse.benchmark;

import java.io.IOException;

import sse.benchmark.configs.BenchmarkConfig;

public interface BenchmarkScenario {

    String name();

    BenchmarkOperation operation();

    void writeHeader(BenchmarkResultWriter resultWriter) throws IOException;

    void run(BenchmarkConfig config, BenchmarkResultWriter resultWriter) throws Exception;
}
