package sse.populatedb;

import java.nio.file.Path;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import sse.demo.client.ConfidentialClientAdapter;
import sse.oram.ORAMSettings;
import sse.vocabulary.VocabularyLoader;
import vss.facade.SecretSharingException;

public final class PopulateDB {

    private static final int DEFAULT_CLIENT_ID = 101;
    private static final Path DEFAULT_INPUT = Paths.get("datasets", "processed", "enron", "keyword_to_docids.ndjson");
    private static final int DEFAULT_BATCH_SIZE = 1_000;
    private static final int DEFAULT_CLIENT_COUNT = 1;
    private static final String USAGE =
            "Usage: PopulateDB [--client-id N] [--client-count N] [--input PATH] "
                    + "[--batch-size N] [--vocabulary PATH]";

    public static void main(String[] args) {
        int clientId = DEFAULT_CLIENT_ID;
        Path inputPath = DEFAULT_INPUT;
        Path vocabularyPath = VocabularyLoader.DEFAULT_VOCABULARY_PATH;
        int batchSize = DEFAULT_BATCH_SIZE;
        int clientCount = DEFAULT_CLIENT_COUNT;

        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            switch (arg) {
                case "--client-id":
                    clientId = parsePositiveInteger(readOptionValue(args, ++i, "--client-id"), "--client-id");
                    break;
                case "--client-count":
                    clientCount = parsePositiveInteger(
                            readOptionValue(args, ++i, "--client-count"),
                            "--client-count"
                    );
                    break;
                case "--input":
                    inputPath = Paths.get(readOptionValue(args, ++i, "--input"));
                    break;
                case "--batch-size":
                    batchSize = parsePositiveInteger(readOptionValue(args, ++i, "--batch-size"), "--batch-size");
                    break;
                case "--vocabulary":
                    vocabularyPath = Paths.get(readOptionValue(args, ++i, "--vocabulary"));
                    break;
                default:
                    throw new IllegalArgumentException("Unknown argument: " + arg + ". " + USAGE);
            }
        }
        validateInputPath(inputPath);
        validateClientRange(clientId, clientCount);

        List<ConfidentialClientAdapter> adapters = new ArrayList<ConfidentialClientAdapter>();
        List<PopulateDBHandler> handlers = new ArrayList<PopulateDBHandler>();
        ExecutorService executor = null;
        try {
            for (int clientIndex = 0; clientIndex < clientCount; clientIndex++) {
                ConfidentialClientAdapter adapter = new ConfidentialClientAdapter(clientId + clientIndex);
                adapters.add(adapter);

                PopulateDBHandler handler = new PopulateDBHandler(adapter, batchSize, vocabularyPath);
                handlers.add(handler);
                handler.initialize();
            }

            System.out.println("Starting population with " + clientCount + " clients...");
            executor = Executors.newFixedThreadPool(clientCount);
            List<Future<PopulateDBHandler.PopulationSummary>> futures =
                    new ArrayList<Future<PopulateDBHandler.PopulationSummary>>(clientCount);
            final Path populationInputPath = inputPath;
            final int populationClientCount = clientCount;

            for (int clientIndex = 0; clientIndex < clientCount; clientIndex++) {
                final int workerIndex = clientIndex;
                final PopulateDBHandler handler = handlers.get(clientIndex);
                futures.add(executor.submit(
                        () -> handler.populate(populationInputPath, workerIndex, populationClientCount)
                ));
            }
            executor.shutdown();

            PopulateDBHandler.PopulationSummary summary = aggregateSummaries(futures);
            System.out.println("PopulateDB finished.");
            System.out.println("Processed keywords: " + summary.processedKeywords());
            System.out.println("Processed doc IDs: " + summary.processedDocIds());
            System.out.println("Sent bulk batches: " + summary.sentBatches());
            System.out.println("Population clients: " + clientCount);
        } catch (SecretSharingException e) {
            throw new RuntimeException("Error creating PopulateDB client", e);
        } finally {
            if (executor != null) {
                executor.shutdownNow();
                awaitExecutorTermination(executor);
            }
            for (PopulateDBHandler handler : handlers) {
                handler.close();
            }
            for (ConfidentialClientAdapter adapter : adapters) {
                adapter.close();
            }
        }
    }

    private static PopulateDBHandler.PopulationSummary aggregateSummaries(
            List<Future<PopulateDBHandler.PopulationSummary>> futures) {
        long processedKeywords = 0L;
        long processedDocIds = 0L;
        long sentBatches = 0L;

        try {
            for (Future<PopulateDBHandler.PopulationSummary> future : futures) {
                PopulateDBHandler.PopulationSummary summary = future.get();
                processedKeywords += summary.processedKeywords();
                processedDocIds += summary.processedDocIds();
                sentBatches += summary.sentBatches();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for population clients", e);
        } catch (ExecutionException e) {
            throw new IllegalStateException("A population client failed", e.getCause());
        }

        return new PopulateDBHandler.PopulationSummary(
                processedKeywords,
                processedDocIds,
                sentBatches
        );
    }

    private static void awaitExecutorTermination(ExecutorService executor) {
        try {
            executor.awaitTermination(10, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static void validateClientRange(int firstClientId, int clientCount) {
        long highestClientId = (long) firstClientId + clientCount - 1L;
        if (highestClientId > Integer.MAX_VALUE - ORAMSettings.DEFAULT_ORAM_CLIENT_ID_OFFSET) {
            throw new IllegalArgumentException("Population client IDs exceed the supported ORAM client ID range");
        }
    }

    private static void validateInputPath(Path inputPath) {
        if (inputPath == null) {
            throw new IllegalArgumentException("input path cannot be null");
        }
        if (!Files.exists(inputPath) || !Files.isRegularFile(inputPath)) {
            throw new IllegalArgumentException("NDJSON file does not exist: " + inputPath.toAbsolutePath());
        }
    }

    private static String readOptionValue(String[] args, int valueIndex, String optionName) {
        if (valueIndex >= args.length) {
            throw new IllegalArgumentException("Missing value for " + optionName + ". " + USAGE);
        }
        String value = args[valueIndex];
        if (value.startsWith("--")) {
            throw new IllegalArgumentException("Missing value for " + optionName + ". " + USAGE);
        }
        return value;
    }

    private static int parsePositiveInteger(String rawValue, String optionName) {
        try {
            int value = Integer.parseInt(rawValue);
            if (value <= 0) {
                throw new IllegalArgumentException(optionName + " must be greater than zero");
            }
            return value;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Invalid " + optionName + " value: " + rawValue, e);
        }
    }
}
