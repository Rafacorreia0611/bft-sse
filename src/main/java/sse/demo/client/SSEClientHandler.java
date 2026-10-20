package sse.demo.client;

import java.nio.file.Path;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import javax.crypto.SecretKey;

import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.search.SearchToken;
import sse.domain.state.KeywordBlock;
import sse.domain.state.State;
import sse.facade.SSEClientFacade;
import sse.metrics.SearchOperationMetrics;
import sse.metrics.UpdateOperationMetrics;
import sse.oram.ORAMAdapter;
import sse.oram.ORAMSettings;
import sse.vocabulary.VocabularyLoader;

public final class SSEClientHandler {

    private static final long LOCK_RETRY_DELAY_MS = 250L;

    private final ConfidentialClientAdapter adapter;
    private final SSEClientFacade sseClientFacade;
    private final ORAMSettings oramSettings;
    private final ORAMAdapter oramAdapter;
    private final SSEInitCoordinator initCoordinator;

    public SSEClientHandler(ConfidentialClientAdapter adapter) {
        this(adapter, VocabularyLoader.DEFAULT_VOCABULARY_PATH);
    }

    public SSEClientHandler(ConfidentialClientAdapter adapter, Path vocabularyPath) {
        if (adapter == null) {
            throw new IllegalArgumentException("adapter cannot be null");
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
    }

    public void initializeState() {
        initCoordinator.initializeOrConnect();
    }

    public List<String> search(String keyword) {
        return searchInternal(keyword, null);
    }

    public List<String> search(String keyword, SearchOperationMetrics metrics) {
        if (metrics == null) {
            throw new IllegalArgumentException("metrics cannot be null");
        }
        return searchInternal(keyword, metrics);
    }

    private List<String> searchInternal(String keyword, SearchOperationMetrics metrics) {
        long phaseStart = startTiming(metrics);
        String normalizedKeyword = sseClientFacade.normalizeKeyword(keyword);
        if (metrics != null) {
            metrics.recordNormalizationLatency(System.nanoTime() - phaseStart);
        }
        if (normalizedKeyword == null || normalizedKeyword.isEmpty()) {
            throw new IllegalArgumentException("keyword cannot be normalized: " + keyword);
        }

        phaseStart = startTiming(metrics);
        ConfidentialClientAdapter.StateRequestResult stateRequest = adapter.requestState();
        State state = stateRequest.state();
        SecretKey masterKey = stateRequest.masterKey();
        if (metrics != null) {
            metrics.recordStateRequestLatency(System.nanoTime() - phaseStart);
        }

        phaseStart = startTiming(metrics);
        Integer keywordLocation = sseClientFacade.resolveKeywordLocation(masterKey, state, normalizedKeyword);
        if (metrics != null) {
            metrics.recordAddressResolutionLatency(System.nanoTime() - phaseStart);
        }
        if (keywordLocation == null) {
            throw new IllegalArgumentException("keyword is outside the vocabulary: " + keyword);
        }

        phaseStart = startTiming(metrics);
        KeywordBlock keywordBlock = oramAdapter.readKeywordBlock(keywordLocation);
        if (metrics != null) {
            metrics.recordOramReadLatency(System.nanoTime() - phaseStart);
            metrics.recordObservedChainLength(
                    keywordBlock.keywordState() == null ? 0 : keywordBlock.keywordState().counter());
        }

        phaseStart = startTiming(metrics);
        SearchToken searchToken = sseClientFacade.generateSearchToken(
                masterKey,
                keywordBlock.keywordState(),
                normalizedKeyword
        );
        if (metrics != null) {
            metrics.recordTokenBuildLatency(System.nanoTime() - phaseStart);
        }
        if (searchToken == null) {
            return Collections.emptyList();
        }

        phaseStart = startTiming(metrics);
        Map<EncryptedUpdateTuple, SecretKey> searchResults = adapter.sendSearchRequest(searchToken);
        if (metrics != null) {
            metrics.recordSearchRequestRoundTripLatency(System.nanoTime() - phaseStart);
        }

        phaseStart = startTiming(metrics);
        List<String> docIds = sseClientFacade.extractAddedDocIds(searchResults);
        if (metrics != null) {
            metrics.recordResultProcessingLatency(System.nanoTime() - phaseStart);
        }
        return docIds;
    }

    private static long startTiming(SearchOperationMetrics metrics) {
        return metrics == null ? 0L : System.nanoTime();
    }

    public void update(KeywordUpdate update) {
        updateInternal(update, null);
    }

    public void update(KeywordUpdate update, UpdateOperationMetrics metrics) {
        if (metrics == null) {
            throw new IllegalArgumentException("metrics cannot be null");
        }
        updateInternal(update, metrics);
    }

    private void updateInternal(KeywordUpdate update, UpdateOperationMetrics metrics) {
        if (update == null) {
            throw new IllegalArgumentException("update cannot be null");
        }

        long phaseStart = startTiming(metrics);
        String normalizedKeyword = sseClientFacade.normalizeKeyword(update.keyword());
        if (metrics != null) {
            metrics.recordNormalizationLatency(System.nanoTime() - phaseStart);
        }
        if (normalizedKeyword == null || normalizedKeyword.isEmpty()) {
            throw new IllegalArgumentException("keyword cannot be normalized: " + update.keyword());
        }

        phaseStart = startTiming(metrics);
        ConfidentialClientAdapter.StateRequestResult stateRequest = adapter.requestState();
        State state = stateRequest.state();
        SecretKey masterKey = stateRequest.masterKey();
        if (metrics != null) {
            metrics.recordStateRequestLatency(System.nanoTime() - phaseStart);
        }

        phaseStart = startTiming(metrics);
        Integer keywordLocation = sseClientFacade.resolveKeywordLocation(masterKey, state, normalizedKeyword);
        if (metrics != null) {
            metrics.recordAddressResolutionLatency(System.nanoTime() - phaseStart);
        }
        if (keywordLocation == null) {
            throw new IllegalArgumentException("keyword is outside the vocabulary: " + update.keyword());
        }
        KeywordUpdate canonicalUpdate = new KeywordUpdate(
                normalizedKeyword,
                update.docIds(),
                update.operation()
        );

        phaseStart = startTiming(metrics);
        KeywordBlock oldBlock;
        while (true) {
            oldBlock = oramAdapter.acquireKeywordLock(keywordLocation);
            if (!oldBlock.locked()) {
                break;
            }
            sleepBeforeLockRetry();
        }
        if (metrics != null) {
            metrics.recordOramLockLatency(System.nanoTime() - phaseStart);
        }

        boolean updateCommitted = false;
        try {
            phaseStart = startTiming(metrics);
            PreparedUpdateRequest preparedUpdateRequest = sseClientFacade.prepareUpdateRequest(
                    masterKey,
                    oldBlock.keywordState(),
                    canonicalUpdate
            );
            SecretKey[] tupleKeys = preparedUpdateRequest.tupleKeys()
                    .toArray(new SecretKey[preparedUpdateRequest.tupleKeys().size()]);
            if (metrics != null) {
                metrics.recordTokenBuildLatency(System.nanoTime() - phaseStart);
            }

            phaseStart = startTiming(metrics);
            updateCommitted = adapter.sendUpdateRequest(preparedUpdateRequest.updateToken(), tupleKeys);
            if (metrics != null) {
                metrics.recordUpdateRequestRoundTripLatency(System.nanoTime() - phaseStart);
            }
            if (!updateCommitted) {
                throw new IllegalStateException("Server rejected update");
            }

            phaseStart = startTiming(metrics);
            oramAdapter.publishKeywordState(keywordLocation, preparedUpdateRequest.keywordState());
            if (metrics != null) {
                metrics.recordOramPublishLatency(System.nanoTime() - phaseStart);
            }
        } finally {
            if (!updateCommitted) {
                oramAdapter.releaseKeywordLock(keywordLocation);
            }
        }
    }

    private static long startTiming(UpdateOperationMetrics metrics) {
        return metrics == null ? 0L : System.nanoTime();
    }

    private void sleepBeforeLockRetry() {
        try {
            Thread.sleep(LOCK_RETRY_DELAY_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("Interrupted while waiting to retry keyword lock", e);
        }
    }

    public void close() {
        oramAdapter.close();
    }
}
