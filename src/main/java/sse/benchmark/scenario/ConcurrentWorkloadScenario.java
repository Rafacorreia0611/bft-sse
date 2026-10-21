package sse.benchmark.scenario;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

import sse.benchmark.BenchmarkOperation;
import sse.benchmark.BenchmarkResultWriter;
import sse.benchmark.BenchmarkScenario;
import sse.benchmark.ConcurrentOperationResult;
import sse.benchmark.KeywordSelectionDistribution;
import sse.benchmark.configs.BenchmarkConfig;
import sse.benchmark.configs.ConcurrentWorkloadConfig;
import sse.dataset.KeywordDocIdsEntry;
import sse.dataset.KeywordDocIdsReader;
import sse.demo.client.ConfidentialClientAdapter;
import sse.demo.client.SSEClientHandler;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.UpdateOp;
import sse.metrics.SearchOperationMetrics;
import sse.metrics.UpdateOperationMetrics;
import vss.facade.SecretSharingException;

public final class ConcurrentWorkloadScenario implements BenchmarkScenario {

    private static final long COORDINATION_TIMEOUT_SECONDS = 300L;
    private static final String WARMUP_DOCUMENT_PREFIX = "cw";
    private static final String MEASUREMENT_DOCUMENT_PREFIX = "cm";
    private static final int DOCUMENTS_PER_UPDATE = 1;

    @Override
    public String name() {
        return "concurrent-workload";
    }

    @Override
    public void writeHeader(BenchmarkResultWriter resultWriter) throws IOException {
        resultWriter.writeConcurrentHeader();
    }

    @Override
    public void run(BenchmarkConfig config, BenchmarkResultWriter resultWriter) throws Exception {
        if (!(config instanceof ConcurrentWorkloadConfig)) {
            throw new IllegalArgumentException("Concurrent scenario requires ConcurrentWorkloadConfig");
        }
        ConcurrentWorkloadConfig scenarioConfig = (ConcurrentWorkloadConfig) config;
        Path vocabularyPath = Paths.get(scenarioConfig.vocabularyPath());
        validateVocabularyPath(vocabularyPath);

        List<KeywordDocIdsEntry> entries = loadEntries(scenarioConfig.inputPath());
        validateKeywordPools(entries, scenarioConfig.warmupKeywordCount());
        List<KeywordDocIdsEntry> warmupEntries = entries.subList(0, scenarioConfig.warmupKeywordCount());
        List<KeywordDocIdsEntry> measurementEntries =
                entries.subList(scenarioConfig.warmupKeywordCount(), entries.size());
        double[] warmupSelectionCdf = buildSelectionCdf(warmupEntries.size(), scenarioConfig);
        double[] measurementSelectionCdf = buildSelectionCdf(measurementEntries.size(), scenarioConfig);

        List<ConfidentialClientAdapter> adapters = new ArrayList<ConfidentialClientAdapter>();
        List<SSEClientHandler> clientHandlers = new ArrayList<SSEClientHandler>();
        ExecutorService executor = null;
        CountDownLatch warmupStart = new CountDownLatch(1);
        CountDownLatch measurementStart = new CountDownLatch(1);

        try {
            createAndInitializeClients(scenarioConfig, vocabularyPath, adapters, clientHandlers);
            executor = Executors.newFixedThreadPool(scenarioConfig.clientCount());

            CountDownLatch workersReady = new CountDownLatch(scenarioConfig.clientCount());
            CountDownLatch warmupFinished = new CountDownLatch(scenarioConfig.clientCount());
            AtomicLong warmupDeadlineNanos = new AtomicLong();
            AtomicLong measurementStartNanos = new AtomicLong();
            AtomicLong measurementDeadlineNanos = new AtomicLong();
            AtomicReference<Throwable> firstFailure = new AtomicReference<Throwable>();
            List<Future<List<ConcurrentOperationResult>>> futures =
                    new ArrayList<Future<List<ConcurrentOperationResult>>>(scenarioConfig.clientCount());

            for (int clientIndex = 0; clientIndex < scenarioConfig.clientCount(); clientIndex++) {
                final int workerIndex = clientIndex;
                final SSEClientHandler handler = clientHandlers.get(clientIndex);
                futures.add(executor.submit(() -> runClient(
                        workerIndex,
                        handler,
                        scenarioConfig,
                        warmupEntries,
                        measurementEntries,
                        warmupSelectionCdf,
                        measurementSelectionCdf,
                        workersReady,
                        warmupStart,
                        warmupFinished,
                        measurementStart,
                        warmupDeadlineNanos,
                        measurementStartNanos,
                        measurementDeadlineNanos,
                        firstFailure
                )));
            }

            awaitLatch(workersReady, COORDINATION_TIMEOUT_SECONDS, "clients to become ready");
            System.out.println("Starting " + scenarioConfig.warmupSeconds() + " second warm-up with "
                    + scenarioConfig.clientCount() + " clients...");
            warmupDeadlineNanos.set(System.nanoTime()
                    + TimeUnit.SECONDS.toNanos(scenarioConfig.warmupSeconds()));
            warmupStart.countDown();
            awaitLatch(
                    warmupFinished,
                    scenarioConfig.warmupSeconds() + COORDINATION_TIMEOUT_SECONDS,
                    "clients to finish warm-up"
            );
            rethrowWorkerFailure(firstFailure.get());

            long measuredStart = System.nanoTime();
            measurementStartNanos.set(measuredStart);
            measurementDeadlineNanos.set(measuredStart
                    + TimeUnit.SECONDS.toNanos(scenarioConfig.measurementSeconds()));
            measurementStart.countDown();

            List<ConcurrentOperationResult> results = new ArrayList<ConcurrentOperationResult>();
            long completionDeadline = measuredStart + TimeUnit.SECONDS.toNanos(
                    scenarioConfig.measurementSeconds() + COORDINATION_TIMEOUT_SECONDS);
            for (Future<List<ConcurrentOperationResult>> future : futures) {
                long remainingNanos = completionDeadline - System.nanoTime();
                if (remainingNanos <= 0L) {
                    throw new TimeoutException("Timed out waiting for concurrent benchmark clients to finish");
                }
                results.addAll(future.get(remainingNanos, TimeUnit.NANOSECONDS));
            }
            rethrowWorkerFailure(firstFailure.get());

            Collections.sort(results, Comparator
                    .comparingLong(ConcurrentOperationResult::startOffsetNanos)
                    .thenComparingInt(ConcurrentOperationResult::clientId)
                    .thenComparingLong(ConcurrentOperationResult::clientOperation));
            int searchCount = 0;
            for (ConcurrentOperationResult result : results) {
                resultWriter.writeConcurrentSample(name(), result);
                if (result.operation() == BenchmarkOperation.SEARCH) {
                    searchCount++;
                }
            }

            double throughput = results.size() / (double) scenarioConfig.measurementSeconds();
            printSummary(results.size(), searchCount, throughput, scenarioConfig.searchPercentage());
        } finally {
            warmupStart.countDown();
            measurementStart.countDown();
            if (executor != null) {
                executor.shutdownNow();
            }
            closeClients(clientHandlers, adapters);
        }
    }

    private List<ConcurrentOperationResult> runClient(
            int clientIndex,
            SSEClientHandler clientHandler,
            ConcurrentWorkloadConfig config,
            List<KeywordDocIdsEntry> warmupEntries,
            List<KeywordDocIdsEntry> measurementEntries,
            double[] warmupSelectionCdf,
            double[] measurementSelectionCdf,
            CountDownLatch workersReady,
            CountDownLatch warmupStart,
            CountDownLatch warmupFinished,
            CountDownLatch measurementStart,
            AtomicLong warmupDeadlineNanos,
            AtomicLong measurementStartNanos,
            AtomicLong measurementDeadlineNanos,
            AtomicReference<Throwable> firstFailure) {
        List<ConcurrentOperationResult> results = new ArrayList<ConcurrentOperationResult>();
        Random random = new Random(config.seed() + clientIndex);
        int clientId = config.clientIdForIndex(clientIndex);
        boolean warmupFinishedSignalled = false;

        try {
            workersReady.countDown();
            warmupStart.await();

            long warmupOperation = 1L;
            while (firstFailure.get() == null && System.nanoTime() < warmupDeadlineNanos.get()) {
                BenchmarkOperation selectedOperation = selectOperation(random, config.searchPercentage());
                KeywordDocIdsEntry entry = selectEntry(warmupEntries, warmupSelectionCdf, random);
                runWarmupOperation(
                        selectedOperation,
                        clientHandler,
                        entry.keyword(),
                        clientId,
                        warmupOperation++
                );
            }
            warmupFinished.countDown();
            warmupFinishedSignalled = true;

            measurementStart.await();
            long clientOperation = 1L;
            while (firstFailure.get() == null) {
                long operationStart = System.nanoTime();
                if (operationStart >= measurementDeadlineNanos.get()) {
                    break;
                }

                BenchmarkOperation selectedOperation = selectOperation(random, config.searchPercentage());
                KeywordDocIdsEntry entry = selectEntry(measurementEntries, measurementSelectionCdf, random);
                results.add(runMeasuredOperation(
                        selectedOperation,
                        clientHandler,
                        entry.keyword(),
                        config.clientCount(),
                        clientId,
                        clientOperation,
                        operationStart - measurementStartNanos.get(),
                        operationStart
                ));
                clientOperation++;
            }
        } catch (Throwable failure) {
            firstFailure.compareAndSet(null, failure);
        } finally {
            if (!warmupFinishedSignalled) {
                warmupFinished.countDown();
            }
        }
        return results;
    }

    private void runWarmupOperation(BenchmarkOperation selectedOperation,
                                    SSEClientHandler clientHandler,
                                    String keyword,
                                    int clientId,
                                    long clientOperation) {
        if (selectedOperation == BenchmarkOperation.SEARCH) {
            clientHandler.search(keyword);
            return;
        }
        clientHandler.update(addUpdate(keyword, WARMUP_DOCUMENT_PREFIX, clientId, clientOperation));
    }

    private ConcurrentOperationResult runMeasuredOperation(BenchmarkOperation selectedOperation,
                                                           SSEClientHandler clientHandler,
                                                           String keyword,
                                                           int clientCount,
                                                           int clientId,
                                                           long clientOperation,
                                                           long startOffsetNanos,
                                                           long operationStartNanos) {
        if (selectedOperation == BenchmarkOperation.SEARCH) {
            SearchOperationMetrics metrics = new SearchOperationMetrics();
            clientHandler.search(keyword, metrics);
            long operationEndNanos = System.nanoTime();
            return ConcurrentOperationResult.forSearch(
                    clientCount,
                    clientId,
                    clientOperation,
                    keyword,
                    startOffsetNanos,
                    operationEndNanos - operationStartNanos,
                    metrics
            );
        }

        UpdateOperationMetrics metrics = new UpdateOperationMetrics();
        clientHandler.update(
                addUpdate(keyword, MEASUREMENT_DOCUMENT_PREFIX, clientId, clientOperation),
                metrics
        );
        long operationEndNanos = System.nanoTime();
        return ConcurrentOperationResult.forUpdate(
                clientCount,
                clientId,
                clientOperation,
                keyword,
                DOCUMENTS_PER_UPDATE,
                startOffsetNanos,
                operationEndNanos - operationStartNanos,
                metrics
        );
    }

    private BenchmarkOperation selectOperation(Random random, int searchPercentage) {
        return random.nextInt(100) < searchPercentage
                ? BenchmarkOperation.SEARCH
                : BenchmarkOperation.UPDATE;
    }

    private KeywordUpdate addUpdate(String keyword,
                                    String documentPrefix,
                                    int clientId,
                                    long clientOperation) {
        return new KeywordUpdate(
                keyword,
                documentIds(documentPrefix, clientId, clientOperation),
                UpdateOp.ADD
        );
    }

    private List<String> documentIds(String prefix, int clientId, long clientOperation) {
        String baseId = prefix + '-' + clientId + '-' + clientOperation;
        if (DOCUMENTS_PER_UPDATE == 1) {
            return Collections.singletonList(baseId);
        }

        List<String> documentIds = new ArrayList<String>(DOCUMENTS_PER_UPDATE);
        for (int documentIndex = 1; documentIndex <= DOCUMENTS_PER_UPDATE; documentIndex++) {
            documentIds.add(baseId + '-' + documentIndex);
        }
        return documentIds;
    }

    private void printSummary(int operationCount,
                              int searchCount,
                              double throughput,
                              int searchPercentage) {
        if (searchPercentage == 100) {
            System.out.println("Measured " + operationCount + " completed searches; throughput="
                    + throughput + " ops/s.");
            return;
        }
        if (searchPercentage == 0) {
            System.out.println("Measured " + operationCount + " completed updates; throughput="
                    + throughput + " ops/s.");
            return;
        }

        int updateCount = operationCount - searchCount;
        System.out.println("Measured " + operationCount + " completed operations ("
                + searchCount + " searches, " + updateCount + " updates); throughput="
                + throughput + " ops/s.");
    }

    private double[] buildSelectionCdf(int keywordCount, ConcurrentWorkloadConfig config) {
        if (config.keywordSelectionDistribution() != KeywordSelectionDistribution.ZIPFIAN) {
            return null;
        }

        double[] cumulativeProbabilities = new double[keywordCount];
        double totalWeight = 0.0;
        for (int index = 0; index < keywordCount; index++) {
            double weight = 1.0 / Math.pow(index + 1, config.zipfianExponent());
            cumulativeProbabilities[index] = weight;
            totalWeight += weight;
        }

        double cumulativeProbability = 0.0;
        for (int index = 0; index < keywordCount; index++) {
            cumulativeProbability += cumulativeProbabilities[index] / totalWeight;
            cumulativeProbabilities[index] = cumulativeProbability;
        }
        cumulativeProbabilities[keywordCount - 1] = 1.0;
        return cumulativeProbabilities;
    }

    private KeywordDocIdsEntry selectEntry(List<KeywordDocIdsEntry> entries,
                                            double[] selectionCdf,
                                            Random random) {
        if (selectionCdf == null) {
            return entries.get(random.nextInt(entries.size()));
        }

        int index = Arrays.binarySearch(selectionCdf, random.nextDouble());
        if (index < 0) {
            index = -index - 1;
        }
        return entries.get(index);
    }

    private void awaitLatch(CountDownLatch latch, long timeoutSeconds, String description)
            throws InterruptedException, TimeoutException {
        if (!latch.await(timeoutSeconds, TimeUnit.SECONDS)) {
            throw new TimeoutException("Timed out waiting for " + description);
        }
    }

    private void createAndInitializeClients(ConcurrentWorkloadConfig config,
                                            Path vocabularyPath,
                                            List<ConfidentialClientAdapter> adapters,
                                            List<SSEClientHandler> clientHandlers) {
        for (int clientIndex = 0; clientIndex < config.clientCount(); clientIndex++) {
            int clientId = config.clientIdForIndex(clientIndex);
            ConfidentialClientAdapter adapter = createAdapter(clientId);
            adapters.add(adapter);
            SSEClientHandler clientHandler = new SSEClientHandler(adapter, vocabularyPath);
            clientHandlers.add(clientHandler);
            clientHandler.initializeState();
        }
    }

    private ConfidentialClientAdapter createAdapter(int clientId) {
        try {
            return new ConfidentialClientAdapter(clientId);
        } catch (SecretSharingException e) {
            throw new IllegalStateException("Failed to create benchmark client with id " + clientId, e);
        }
    }

    private void closeClients(List<SSEClientHandler> clientHandlers,
                              List<ConfidentialClientAdapter> adapters) {
        for (SSEClientHandler clientHandler : clientHandlers) {
            clientHandler.close();
        }
        for (ConfidentialClientAdapter adapter : adapters) {
            adapter.close();
        }
    }

    private void rethrowWorkerFailure(Throwable failure) throws Exception {
        if (failure == null) {
            return;
        }
        if (failure instanceof Exception) {
            throw (Exception) failure;
        }
        if (failure instanceof Error) {
            throw (Error) failure;
        }
        throw new IllegalStateException("Concurrent benchmark worker failed", failure);
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

    private void validateKeywordPools(List<KeywordDocIdsEntry> entries, int warmupKeywordCount) {
        if (entries.size() <= warmupKeywordCount) {
            throw new IllegalArgumentException("Benchmark input requires more than " + warmupKeywordCount
                    + " entries: the first entries are reserved for warm-up and at least one is needed for "
                    + "measurement");
        }
    }
}
