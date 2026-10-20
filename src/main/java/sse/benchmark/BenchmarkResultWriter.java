package sse.benchmark;

import java.io.BufferedWriter;
import java.io.Closeable;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import sse.metrics.SearchOperationMetrics;
import sse.metrics.UpdateOperationMetrics;

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
        writer.write("scenario,operation,run,keyword,doc_count,expected_db_size_before,"
                + "total_latency_ns,normalization_latency_ns,state_request_latency_ns,"
                + "address_resolution_latency_ns,oram_lock_latency_ns,token_build_latency_ns,"
                + "update_request_round_trip_latency_ns,oram_publish_latency_ns");
        writer.newLine();
    }

    public void writeConcurrentSearchHeader() throws IOException {
        writer.write("scenario,operation,client_count,client_id,client_operation,keyword,result_count,"
                + "chain_length,start_offset_ns,total_latency_ns,normalization_latency_ns,"
                + "state_request_latency_ns,address_resolution_latency_ns,oram_read_latency_ns,"
                + "token_build_latency_ns,search_request_round_trip_latency_ns,"
                + "result_processing_latency_ns");
        writer.newLine();
    }

    public void writeConcurrentSearchSample(String scenarioName,
                                            BenchmarkOperation operation,
                                            ConcurrentOperationResult result) throws IOException {
        SearchOperationMetrics metrics = result.searchMetrics();
        writer.write(csvValue(scenarioName));
        writer.write(',');
        writer.write(csvValue(operation.name()));
        writer.write(',');
        writer.write(Integer.toString(result.clientCount()));
        writer.write(',');
        writer.write(Integer.toString(result.clientId()));
        writer.write(',');
        writer.write(Long.toString(result.clientOperation()));
        writer.write(',');
        writer.write(csvValue(result.keyword()));
        writer.write(',');
        writer.write(Integer.toString(result.resultCount()));
        writer.write(',');
        writer.write(Integer.toString(metrics.observedChainLength()));
        writer.write(',');
        writer.write(Long.toString(result.startOffsetNanos()));
        writer.write(',');
        writer.write(Long.toString(result.totalLatencyNanos()));
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

    public void writeConcurrentUpdateHeader() throws IOException {
        writer.write("scenario,operation,client_count,client_id,client_operation,keyword,"
                + "updated_document_count,chain_length_before,start_offset_ns,total_latency_ns,"
                + "normalization_latency_ns,state_request_latency_ns,address_resolution_latency_ns,"
                + "oram_lock_latency_ns,token_build_latency_ns,update_request_round_trip_latency_ns,"
                + "oram_publish_latency_ns");
        writer.newLine();
    }

    public void writeConcurrentUpdateSample(String scenarioName,
                                            BenchmarkOperation operation,
                                            ConcurrentOperationResult result) throws IOException {
        UpdateOperationMetrics metrics = result.updateMetrics();
        writer.write(csvValue(scenarioName));
        writer.write(',');
        writer.write(csvValue(operation.name()));
        writer.write(',');
        writer.write(Integer.toString(result.clientCount()));
        writer.write(',');
        writer.write(Integer.toString(result.clientId()));
        writer.write(',');
        writer.write(Long.toString(result.clientOperation()));
        writer.write(',');
        writer.write(csvValue(result.keyword()));
        writer.write(',');
        writer.write(Integer.toString(result.updatedDocumentCount()));
        writer.write(',');
        writer.write(Integer.toString(metrics.observedChainLengthBefore()));
        writer.write(',');
        writer.write(Long.toString(result.startOffsetNanos()));
        writer.write(',');
        writer.write(Long.toString(result.totalLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.normalizationLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.stateRequestLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.addressResolutionLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.oramLockLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.tokenBuildLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.updateRequestRoundTripLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.oramPublishLatencyNanos()));
        writer.newLine();
    }

    public void writeUpdateSample(String scenarioName,
                                  BenchmarkOperation operation,
                                  int run,
                                  String keyword,
                                  int docIdCount,
                                  long expectedDbSizeBefore,
                                  long totalLatencyNanos,
                                  UpdateOperationMetrics metrics) throws IOException {
        writer.write(csvValue(scenarioName));
        writer.write(',');
        writer.write(csvValue(operation.name()));
        writer.write(',');
        writer.write(Integer.toString(run));
        writer.write(',');
        writer.write(csvValue(keyword));
        writer.write(',');
        writer.write(Integer.toString(docIdCount));
        writer.write(',');
        writer.write(Long.toString(expectedDbSizeBefore));
        writer.write(',');
        writer.write(Long.toString(totalLatencyNanos));
        writer.write(',');
        writer.write(Long.toString(metrics.normalizationLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.stateRequestLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.addressResolutionLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.oramLockLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.tokenBuildLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.updateRequestRoundTripLatencyNanos()));
        writer.write(',');
        writer.write(Long.toString(metrics.oramPublishLatencyNanos()));
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
