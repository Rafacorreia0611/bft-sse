package sse.benchmark.scenario;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import sse.benchmark.BenchmarkOperation;
import sse.benchmark.BenchmarkResultWriter;
import sse.benchmark.BenchmarkScenario;
import sse.benchmark.configs.BenchmarkConfig;
import sse.benchmark.configs.UpdateLatencyByDocsConfig;
import sse.dataset.KeywordDocIdsEntry;
import sse.dataset.KeywordDocIdsReader;
import sse.demo.client.ConfidentialClientAdapter;
import sse.demo.client.SSEClientHandler;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.UpdateOp;
import sse.metrics.UpdateOperationMetrics;
import vss.facade.SecretSharingException;

public final class UpdateLatencyByDocsScenario implements BenchmarkScenario {

    @Override
    public String name() {
        return "update-latency-by-docs";
    }

    @Override
    public BenchmarkOperation operation() {
        return BenchmarkOperation.UPDATE;
    }

    @Override
    public void writeHeader(BenchmarkResultWriter resultWriter) throws IOException {
        resultWriter.writeUpdateHeader();
    }

    @Override
    public void run(BenchmarkConfig config, BenchmarkResultWriter resultWriter) throws Exception {
        if (!(config instanceof UpdateLatencyByDocsConfig)) {
            throw new IllegalArgumentException("Update scenario requires UpdateLatencyByDocsConfig");
        }
        UpdateLatencyByDocsConfig scenarioConfig = (UpdateLatencyByDocsConfig) config;
        Path vocabularyPath = Paths.get(scenarioConfig.vocabularyPath());
        validateVocabularyPath(vocabularyPath);

        List<KeywordDocIdsEntry> entries = loadEntries(scenarioConfig.inputPath());
        validateEntries(entries, scenarioConfig);

        ConfidentialClientAdapter adapter = createAdapter(scenarioConfig.clientId());
        SSEClientHandler clientHandler = new SSEClientHandler(adapter, vocabularyPath);
        try {
            clientHandler.initializeState();
            System.out.println("Running warm-up updates...");
            runWarmups(clientHandler, entries, scenarioConfig.warmupCount());
            System.out.println("Warm-up updates finished.");
            System.out.println("Running measured updates...");
            runMeasurements(
                    clientHandler,
                    entries,
                    scenarioConfig,
                    resultWriter
            );
            System.out.println("Measured updates finished.");
            verifyMeasurements(
                    clientHandler,
                    entries.subList(scenarioConfig.warmupCount(), entries.size())
            );
            System.out.println("Measured updates verified successfully.");
        } finally {
            clientHandler.close();
            adapter.close();
        }
    }

    private void validateVocabularyPath(Path path) {
        if (!Files.exists(path) || !Files.isRegularFile(path) || !Files.isReadable(path)) {
            throw new IllegalArgumentException("Vocabulary file does not exist or is not readable: "
                    + path.toAbsolutePath());
        }
    }

    private List<KeywordDocIdsEntry> loadEntries(String inputPath) {
        KeywordDocIdsReader datasetReader = new KeywordDocIdsReader();
        Path path = Paths.get(inputPath);
        List<KeywordDocIdsEntry> entries = new ArrayList<KeywordDocIdsEntry>();

        try (BufferedReader reader = datasetReader.openReader(path)) {
            String line;
            long lineNumber = 0L;
            while ((line = reader.readLine()) != null) {
                lineNumber++;
                KeywordDocIdsEntry entry = datasetReader.parseEntry(line, lineNumber);
                if (entry != null) {
                    entries.add(entry);
                }
            }
        } catch (IOException e) {
            throw new IllegalStateException("Failed to read benchmark input " + path.toAbsolutePath(), e);
        }
        return entries;
    }

    private void validateEntries(List<KeywordDocIdsEntry> entries, UpdateLatencyByDocsConfig config) {
        int expectedEntryCount = config.warmupCount() + config.measurementCount();
        if (entries.size() != expectedEntryCount) {
            throw new IllegalArgumentException("Benchmark input must contain exactly " + expectedEntryCount
                    + " entries, but found " + entries.size());
        }

        Set<String> keywords = new HashSet<String>();
        for (KeywordDocIdsEntry entry : entries) {
            String keyword = entry.keyword().trim();
            if (!keywords.add(keyword)) {
                throw new IllegalArgumentException("Benchmark input contains duplicate keyword: " + keyword);
            }
            if (entry.docIds().size() != config.measurementDocCount()) {
                throw new IllegalArgumentException("Keyword '" + keyword + "' must contain exactly "
                        + config.measurementDocCount() + " document IDs, but found " + entry.docIds().size());
            }
            if (new HashSet<String>(entry.docIds()).size() != entry.docIds().size()) {
                throw new IllegalArgumentException("Keyword '" + keyword + "' contains duplicate document IDs");
            }
        }
    }

    private ConfidentialClientAdapter createAdapter(int clientId) {
        try {
            return new ConfidentialClientAdapter(clientId);
        } catch (SecretSharingException e) {
            throw new IllegalStateException("Failed to create benchmark client with id " + clientId, e);
        }
    }

    private void runWarmups(SSEClientHandler clientHandler,
                            List<KeywordDocIdsEntry> entries,
                            int warmupCount) {
        for (int i = 0; i < warmupCount; i++) {
            clientHandler.update(toAddUpdate(entries.get(i)));
        }
    }

    private void runMeasurements(SSEClientHandler clientHandler,
                                 List<KeywordDocIdsEntry> entries,
                                 UpdateLatencyByDocsConfig config,
                                 BenchmarkResultWriter resultWriter) throws IOException {
        for (int i = 0; i < config.measurementCount(); i++) {
            KeywordDocIdsEntry entry = entries.get(config.warmupCount() + i);
            UpdateOperationMetrics metrics = new UpdateOperationMetrics();

            long startTime = System.nanoTime();
            clientHandler.update(toAddUpdate(entry), metrics);
            long totalLatencyNanos = System.nanoTime() - startTime;

            resultWriter.writeUpdateSample(
                    name(),
                    operation(),
                    i + 1,
                    entry.keyword(),
                    entry.docIds().size(),
                    config.expectedDbSizeBefore(i),
                    totalLatencyNanos,
                    metrics
            );
        }
    }

    private void verifyMeasurements(SSEClientHandler clientHandler,
                                    List<KeywordDocIdsEntry> measuredEntries) {
        for (KeywordDocIdsEntry entry : measuredEntries) {
            List<String> results = clientHandler.search(entry.keyword());
            Set<String> actualDocIds = new HashSet<String>(results);
            Set<String> expectedDocIds = new HashSet<String>(entry.docIds());

            if (actualDocIds.size() != results.size()) {
                throw new IllegalStateException("Search returned duplicate document IDs for measured keyword '"
                        + entry.keyword() + "'");
            }
            if (!expectedDocIds.equals(actualDocIds)) {
                throw new IllegalStateException("Update verification failed for keyword '" + entry.keyword()
                        + "': expected=" + expectedDocIds.size() + " documents, actual=" + actualDocIds.size());
            }
        }
    }

    private KeywordUpdate toAddUpdate(KeywordDocIdsEntry entry) {
        return new KeywordUpdate(entry.keyword(), entry.docIds(), UpdateOp.ADD);
    }
}
