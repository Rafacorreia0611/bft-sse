package sse.benchmark.scenario;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
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
import sse.benchmark.configs.BenchmarkConfig;
import sse.benchmark.configs.ConcurrentWorkloadConfig;
import sse.dataset.KeywordDocIdsEntry;
import sse.dataset.KeywordDocIdsReader;
import sse.demo.client.ConfidentialClientAdapter;
import sse.demo.client.SSEClientHandler;
import sse.metrics.SearchOperationMetrics;
import vss.facade.SecretSharingException;

public final class ConcurrentWorkloadScenario implements BenchmarkScenario {

    private static final long COORDINATION_TIMEOUT_SECONDS = 300L;

    @Override
    public String name() {
        return "concurrent-workload";
    }

    @Override
    public BenchmarkOperation operation() {
        return BenchmarkOperation.SEARCH;
    }

    @Override
    public void writeHeader(BenchmarkResultWriter resultWriter) throws IOException {
        resultWriter.writeConcurrentSearchHeader();
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
            for (ConcurrentOperationResult result : results) {
                resultWriter.writeConcurrentSearchSample(name(), operation(), result);
            }

            double throughput = results.size() / (double) scenarioConfig.measurementSeconds();
            System.out.println("Measured " + results.size() + " completed searches; throughput="
                    + throughput + " ops/s.");
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
        boolean warmupFinishedSignalled = false;

        try {
            workersReady.countDown();
            warmupStart.await();

            while (firstFailure.get() == null && System.nanoTime() < warmupDeadlineNanos.get()) {
                KeywordDocIdsEntry entry = randomEntry(warmupEntries, random);
                clientHandler.search(entry.keyword());
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

                KeywordDocIdsEntry entry = randomEntry(measurementEntries, random);
                SearchOperationMetrics metrics = new SearchOperationMetrics();
                List<String> searchResults = clientHandler.search(entry.keyword(), metrics);
                long operationEnd = System.nanoTime();

                results.add(new ConcurrentOperationResult(
                        config.clientCount(),
                        config.clientIdForIndex(clientIndex),
                        clientOperation++,
                        entry.keyword(),
                        searchResults.size(),
                        operationStart - measurementStartNanos.get(),
                        operationEnd - operationStart,
                        metrics
                ));
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

    private KeywordDocIdsEntry randomEntry(List<KeywordDocIdsEntry> entries, Random random) {
        return entries.get(random.nextInt(entries.size()));
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
