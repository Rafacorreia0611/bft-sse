package sse.benchmark.scenario;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import sse.benchmark.BenchmarkBucket;
import sse.benchmark.BenchmarkConfig;
import sse.benchmark.BenchmarkOperation;
import sse.benchmark.BenchmarkResultWriter;
import sse.benchmark.BenchmarkScenario;
import sse.dataset.KeywordDocIdsEntry;
import sse.dataset.KeywordDocIdsReader;
import sse.demo.client.ConfidentialClientAdapter;
import sse.demo.client.SSEClientHandler;
import sse.metrics.SearchOperationMetrics;
import vss.facade.SecretSharingException;

public final class SearchLatencyByDocsScenario implements BenchmarkScenario {

    @Override
    public String name() {
        return "search-latency-by-docs";
    }

    @Override
    public BenchmarkOperation operation() {
        return BenchmarkOperation.SEARCH;
    }

    @Override
    public void writeHeader(BenchmarkResultWriter resultWriter) throws IOException {
        resultWriter.writeSearchHeader();
    }

    @Override
    public void run(BenchmarkConfig config, BenchmarkResultWriter resultWriter) throws Exception {
        Path vocabularyPath = Paths.get(config.vocabularyPath());
        validateVocabularyPath(vocabularyPath);

        List<KeywordDocIdsEntry> entries = loadEntries(config.inputPath());
        Map<BenchmarkBucket, List<KeywordDocIdsEntry>> entriesByBucket = groupEntriesByBucket(entries, config.buckets());
        validateEntries(entriesByBucket, config);

        ConfidentialClientAdapter adapter = createAdapter(config.clientId());
        SSEClientHandler clientHandler = new SSEClientHandler(
                adapter,
                vocabularyPath
        );
        try {
            clientHandler.initializeState();
            runWarmup(clientHandler, entriesByBucket, config);
            runMeasurements(clientHandler, entriesByBucket, config, resultWriter);
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

    private Map<BenchmarkBucket, List<KeywordDocIdsEntry>> groupEntriesByBucket(List<KeywordDocIdsEntry> entries,
                                                                                List<BenchmarkBucket> buckets) {
        Map<BenchmarkBucket, List<KeywordDocIdsEntry>> entriesByBucket =
                new LinkedHashMap<BenchmarkBucket, List<KeywordDocIdsEntry>>();
        for (BenchmarkBucket bucket : buckets) {
            entriesByBucket.put(bucket, new ArrayList<KeywordDocIdsEntry>());
        }

        for (KeywordDocIdsEntry entry : entries) {
            int docCount = activeDocumentCount(entry);
            BenchmarkBucket bucket = findBucket(docCount, buckets);
            if (bucket == null) {
                throw new IllegalArgumentException("Keyword '" + entry.keyword() + "' with " + docCount
                        + " docs does not fit any configured benchmark bucket");
            }
            entriesByBucket.get(bucket).add(entry);
        }
        return entriesByBucket;
    }

    private void validateEntries(Map<BenchmarkBucket, List<KeywordDocIdsEntry>> entriesByBucket, BenchmarkConfig config) {
        int requiredEntriesPerBucket = config.warmupIterations() + config.measurementIterations();
        for (Map.Entry<BenchmarkBucket, List<KeywordDocIdsEntry>> bucketEntries : entriesByBucket.entrySet()) {
            int availableEntries = bucketEntries.getValue().size();
            if (availableEntries < requiredEntriesPerBucket) {
                throw new IllegalArgumentException("Bucket " + bucketEntries.getKey().label() + " requires at least "
                        + requiredEntriesPerBucket + " keywords, but found " + availableEntries);
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

    private void runWarmup(SSEClientHandler clientHandler,
                           Map<BenchmarkBucket, List<KeywordDocIdsEntry>> entriesByBucket,
                           BenchmarkConfig config) {
        for (Map.Entry<BenchmarkBucket, List<KeywordDocIdsEntry>> bucketEntries : entriesByBucket.entrySet()) {
            List<KeywordDocIdsEntry> entries = bucketEntries.getValue();
            for (int i = 0; i < config.warmupIterations(); i++) {
                KeywordDocIdsEntry entry = entries.get(i);
                List<String> results = clientHandler.search(entry.keyword());
                validateResults(entry, results);
            }
        }
    }

    private void runMeasurements(SSEClientHandler clientHandler,
                                 Map<BenchmarkBucket, List<KeywordDocIdsEntry>> entriesByBucket,
                                 BenchmarkConfig config,
                                 BenchmarkResultWriter resultWriter) throws Exception {
        int run = 1;
        for (Map.Entry<BenchmarkBucket, List<KeywordDocIdsEntry>> bucketEntries : entriesByBucket.entrySet()) {
            BenchmarkBucket bucket = bucketEntries.getKey();
            List<KeywordDocIdsEntry> entries = bucketEntries.getValue();
            int startIndex = config.warmupIterations();
            int endIndex = startIndex + config.measurementIterations();

            for (int i = startIndex; i < endIndex; i++) {
                KeywordDocIdsEntry entry = entries.get(i);
                SearchOperationMetrics metrics = new SearchOperationMetrics();

                long startTime = System.nanoTime();
                List<String> results = clientHandler.search(entry.keyword(), metrics);
                long totalLatencyNanos = System.nanoTime() - startTime;

                validateResults(entry, results);
                resultWriter.writeSearchSample(
                        name(),
                        operation(),
                        run++,
                        entry.keyword(),
                        activeDocumentCount(entry),
                        bucket.label(),
                        totalLatencyNanos,
                        metrics
                );
            }
        }
    }

    private BenchmarkBucket findBucket(int docCount, List<BenchmarkBucket> buckets) {
        for (BenchmarkBucket bucket : buckets) {
            if (bucket.contains(docCount)) {
                return bucket;
            }
        }
        return null;
    }

    private int activeDocumentCount(KeywordDocIdsEntry entry) {
        return new HashSet<String>(entry.docIds()).size();
    }

    private void validateResults(KeywordDocIdsEntry entry, List<String> results) {
        Set<String> expectedDocIds = new HashSet<String>(entry.docIds());
        Set<String> actualDocIds = new HashSet<String>(results);

        if (actualDocIds.size() != results.size()) {
            throw new IllegalStateException("Search returned duplicate document IDs for keyword '"
                    + entry.keyword() + "'");
        }
        if (!expectedDocIds.equals(actualDocIds)) {
            throw new IllegalStateException("Search returned a different active document set for keyword '"
                    + entry.keyword() + "': expected=" + expectedDocIds.size()
                    + " documents, actual=" + actualDocIds.size());
        }
    }
}
