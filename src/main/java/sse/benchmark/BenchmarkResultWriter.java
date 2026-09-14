package sse.benchmark;

import java.io.BufferedWriter;
import java.io.Closeable;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import sse.metrics.SearchOperationMetrics;

public final class BenchmarkResultWriter implements Closeable {

    private final BufferedWriter writer;

    public BenchmarkResultWriter(String outputPath) {
        if (outputPath == null || outputPath.trim().isEmpty()) {
            throw new IllegalArgumentException("outputPath cannot be null or empty");
        }

        Path path = Paths.get(outputPath);
        try {
            Path parent = path.getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            this.writer = Files.newBufferedWriter(path, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to create benchmark result file at " + path.toAbsolutePath(), e);
        }
    }

    public void writeSearchHeader() throws IOException {
        writer.write("scenario,operation,run,keyword,doc_count,bucket,"
                + "total_latency_ns,normalization_latency_ns,state_request_latency_ns,"
                + "address_resolution_latency_ns,oram_read_latency_ns,token_build_latency_ns,"
                + "search_request_round_trip_latency_ns,result_processing_latency_ns");
        writer.newLine();
    }

    public void writeSearchSample(String scenarioName,
                                  BenchmarkOperation operation,
                                  int run,
                                  String keyword,
                                  int docCount,
                                  String bucket,
                                  long totalLatencyNanos,
                                  SearchOperationMetrics metrics) throws IOException {
        writer.write(csvValue(scenarioName));
        writer.write(',');
        writer.write(csvValue(operation.name()));
        writer.write(',');
        writer.write(Integer.toString(run));
        writer.write(',');
        writer.write(csvValue(keyword));
        writer.write(',');
        writer.write(Integer.toString(docCount));
        writer.write(',');
        writer.write(csvValue(bucket));
        writer.write(',');
        writer.write(Long.toString(totalLatencyNanos));
        writer.write(',');
        writer.write(Long.toString(metrics.normalizationLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.stateRequestLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.addressResolutionLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.oramReadLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.tokenBuildLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.searchRequestRoundTripLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.resultProcessingLatencyNanos()));
        writer.newLine();
    }

    public void writeUpdateHeader() throws IOException {
        writer.write("scenario,operation,run,phase,associations_per_update,keyword_count,doc_id_count,payload_id,latency_ns");
        writer.newLine();
    }

    public void writeUpdateSample(String scenarioName,
                                  BenchmarkOperation operation,
                                  int run,
                                  String phase,
                                  int associationsPerUpdate,
                                  int keywordCount,
                                  int docIdCount,
                                  String payloadId,
                                  long latencyNanos) throws IOException {
        writer.write(csvValue(scenarioName));
        writer.write(',');
        writer.write(csvValue(operation.name()));
        writer.write(',');
        writer.write(Integer.toString(run));
        writer.write(',');
        writer.write(csvValue(phase));
        writer.write(',');
        writer.write(Integer.toString(associationsPerUpdate));
        writer.write(',');
        writer.write(Integer.toString(keywordCount));
        writer.write(',');
        writer.write(Integer.toString(docIdCount));
        writer.write(',');
        writer.write(csvValue(payloadId));
        writer.write(',');
        writer.write(Long.toString(latencyNanos));
        writer.newLine();
    }

    @Override
    public void close() throws IOException {
        writer.close();
    }

    private String csvValue(String value) {
        if (value == null) {
            return "";
        }

        if (value.indexOf(',') < 0 && value.indexOf('"') < 0 && value.indexOf('\n') < 0) {
            return value;
        }

        return "\"" + value.replace("\"", "\"\"") + "\"";
    }
}
