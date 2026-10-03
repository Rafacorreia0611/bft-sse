package sse.populatedb;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Path;
import java.util.List;

import javax.crypto.SecretKey;

import sse.dataset.KeywordDocIdsEntry;
import sse.dataset.KeywordDocIdsReader;
import sse.demo.client.ConfidentialClientAdapter;
import sse.demo.client.SSEInitCoordinator;
import sse.domain.state.KeywordBlock;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.state.State;
import sse.domain.update.UpdateOp;
import sse.facade.SSEClientFacade;
import sse.oram.ORAMAdapter;
import sse.oram.ORAMSettings;
import sse.vocabulary.VocabularyLoader;

public final class PopulateDBHandler implements AutoCloseable {

    private static final int DEFAULT_BATCH_SIZE = 250;
    private static final long PROGRESS_LOG_INTERVAL_MS = 2_000L;
    private static final long LOCK_RETRY_DELAY_MS = 250L;

    private final ConfidentialClientAdapter adapter;
    private final SSEClientFacade sseClientFacade;
    private final ORAMSettings oramSettings;
    private final ORAMAdapter oramAdapter;
    private final SSEInitCoordinator initCoordinator;
    private final KeywordDocIdsReader datasetReader;
    private final int batchSize;

    public PopulateDBHandler(ConfidentialClientAdapter adapter) {
        this(adapter, DEFAULT_BATCH_SIZE);
    }

    public PopulateDBHandler(ConfidentialClientAdapter adapter, int batchSize) {
        this(adapter, batchSize, VocabularyLoader.DEFAULT_VOCABULARY_PATH);
    }

    public PopulateDBHandler(ConfidentialClientAdapter adapter, int batchSize, Path vocabularyPath) {
        if (adapter == null) {
            throw new IllegalArgumentException("adapter cannot be null");
        }
        if (batchSize <= 0) {
            throw new IllegalArgumentException("batchSize must be greater than zero");
        }
        if (vocabularyPath == null) {
            throw new IllegalArgumentException("vocabularyPath cannot be null");
        }
        this.adapter = adapter;
        this.sseClientFacade = new SSEClientFacade();
        this.oramSettings = ORAMSettings.defaults();
        this.oramAdapter = new ORAMAdapter(
                oramSettings,
                ORAMSettings.oramClientIdFor(adapter.clientId())
        );
        this.initCoordinator = new SSEInitCoordinator(
                adapter,
                sseClientFacade,
                vocabularyPath,
                oramSettings,
                oramAdapter
        );
        this.datasetReader = new KeywordDocIdsReader();
        this.batchSize = batchSize;
    }

    public PopulationSummary populate(Path inputPath) {
        try (BufferedReader reader = datasetReader.openReader(inputPath)) {
            initCoordinator.initializeOrConnect();

            ConfidentialClientAdapter.StateRequestResult stateRequest = adapter.requestState();
            State currentState = stateRequest.state();
            SecretKey masterKey = stateRequest.masterKey();

            long processedKeywords = 0L;
            long processedDocIds = 0L;
            long sentBatches = 0L;
            long startTimeNanos = System.nanoTime();
            long lastProgressLogNanos = startTimeNanos;

            String line;
            long lineNumber = 0L;

            while ((line = reader.readLine()) != null) {
                lineNumber++;
                KeywordDocIdsEntry entry = datasetReader.parseEntry(line, lineNumber);
                if (entry == null) {
                    continue;
                }

                List<String> docIds = entry.docIds();
                int start = 0;
                while (start < docIds.size()) {
                    int end = Math.min(start + batchSize, docIds.size());
                    List<String> batchDocIds = docIds.subList(start, end);
                    int sentDocIds = sendKeywordBatch(
                            new KeywordUpdate(
                                    entry.keyword(),
                                    batchDocIds,
                                    UpdateOp.ADD
                            ),
                            masterKey,
                            currentState
                    );
                    processedDocIds += sentDocIds;
                    sentBatches++;
                    start = end;

                    long now = System.nanoTime();
                    if (shouldLogProgress(lastProgressLogNanos, now)) {
                        printProgress(processedKeywords, processedDocIds, sentBatches, startTimeNanos);
                        lastProgressLogNanos = now;
                    }
                }

                processedKeywords++;
            }

            printProgress(processedKeywords, processedDocIds, sentBatches, startTimeNanos);
            System.out.println();
            return new PopulationSummary(processedKeywords, processedDocIds, sentBatches);
        } catch (IOException e) {
            throw new IllegalStateException("Failed while reading NDJSON input " + inputPath.toAbsolutePath(), e);
        }
    }

    private int sendKeywordBatch(KeywordUpdate update,
                                 SecretKey masterKey, State currentState) {
        String normalizedKeyword = sseClientFacade.normalizeKeyword(update.keyword());
        if (normalizedKeyword == null || normalizedKeyword.isEmpty()) {
            throw new IllegalArgumentException("keyword cannot be normalized: " + update.keyword());
        }
        Integer keywordLocation = sseClientFacade.resolveKeywordLocation(masterKey, currentState, normalizedKeyword);
        if (keywordLocation == null) {
            throw new IllegalArgumentException("keyword is outside the vocabulary: " + update.keyword());
        }
        KeywordUpdate canonicalUpdate = new KeywordUpdate(
                normalizedKeyword,
                update.docIds(),
                update.operation()
        );

        while (true) {
            KeywordBlock oldBlock = oramAdapter.acquireKeywordLock(keywordLocation);
            if (oldBlock.locked()) {
                sleepBeforeLockRetry();
                continue;
            }

            boolean updateCommitted = false;
            try {
                PreparedUpdateRequest preparedUpdateRequest = sseClientFacade.prepareUpdateRequest(
                        masterKey,
                        oldBlock.keywordState(),
                        canonicalUpdate
                );

                if (preparedUpdateRequest.updateToken().items().size() != preparedUpdateRequest.tupleKeys().size()) {
                    throw new IllegalStateException("Update item/key count mismatch: items="
                            + preparedUpdateRequest.updateToken().items().size()
                            + ", keys=" + preparedUpdateRequest.tupleKeys().size());
                }

                SecretKey[] tupleKeys = preparedUpdateRequest.tupleKeys()
                        .toArray(new SecretKey[preparedUpdateRequest.tupleKeys().size()]);
                updateCommitted = adapter.sendUpdateRequest(preparedUpdateRequest.updateToken(), tupleKeys);
                if (!updateCommitted) {
                    throw new IllegalStateException("Server rejected update batch");
                }

                oramAdapter.publishKeywordState(keywordLocation, preparedUpdateRequest.keywordState());
                return preparedUpdateRequest.updateToken().items().size();
            } finally {
                if (!updateCommitted) {
                    oramAdapter.releaseKeywordLock(keywordLocation);
                }
            }
        }
    }

    private boolean shouldLogProgress(long lastProgressLogNanos, long nowNanos) {
        return (nowNanos - lastProgressLogNanos) >= PROGRESS_LOG_INTERVAL_MS * 1_000_000L;
    }

    private void printProgress(long processedKeywords, long processedDocIds, long sentBatches, long startTimeNanos) {
        long elapsedSeconds = Math.max(1L, (System.nanoTime() - startTimeNanos) / 1_000_000_000L);
        String message = "\rPopulateDB progress: keywords=" + processedKeywords
                + " | docIds=" + processedDocIds
                + " | batches=" + sentBatches
                + " | elapsed=" + formatDuration(elapsedSeconds);
        System.out.print(message);
        System.out.flush();
    }

    private String formatDuration(long totalSeconds) {
        long hours = totalSeconds / 3600L;
        long minutes = (totalSeconds % 3600L) / 60L;
        long seconds = totalSeconds % 60L;
        if (hours > 0) {
            return String.format("%dh%02dm%02ds", hours, minutes, seconds);
        }
        if (minutes > 0) {
            return String.format("%dm%02ds", minutes, seconds);
        }
        return String.format("%ds", seconds);
    }

    private void sleepBeforeLockRetry() {
        try {
            Thread.sleep(LOCK_RETRY_DELAY_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting to retry keyword lock", e);
        }
    }

    @Override
    public void close() {
        oramAdapter.close();
    }

    public static final class PopulationSummary {
        private final long processedKeywords;
        private final long processedDocIds;
        private final long sentBatches;

        PopulationSummary(long processedKeywords, long processedDocIds, long sentBatches) {
            this.processedKeywords = processedKeywords;
            this.processedDocIds = processedDocIds;
            this.sentBatches = sentBatches;
        }

        public long processedKeywords() {
            return processedKeywords;
        }

        public long processedDocIds() {
            return processedDocIds;
        }

        public long sentBatches() {
            return sentBatches;
        }
    }

}
