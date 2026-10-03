package sse.service.server;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.Prf;
import sse.domain.search.SearchResponseData;
import sse.domain.search.SearchToken;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.update.UpdateOp;
import sse.service.client.UpdateTokenService;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public class SearchServiceTest {

    private static final SecretKey MASTER_KEY = new SecretKeySpec(
            "a fixed master key for testing!!".getBytes(StandardCharsets.UTF_8),
            Prf.ALGORITHM);

    private final UpdateTokenService updateTokenService = new UpdateTokenService();
    private final UpdateService updateService = new UpdateService();
    private final SearchService searchService = new SearchService();

    @Test
    public void walksFastChainAndReturnsUpdatesInChronologicalOrder() {
        PreparedUpdateRequest updateRequest = prepareTwoUpdates();
        VerifiableShare firstShare = new VerifiableShare();
        VerifiableShare secondShare = new VerifiableShare();
        SSEServerState state = new SSEServerState();
        updateService.update(
                state,
                updateRequest.updateToken(),
                new VerifiableShare[] {firstShare, secondShare});

        SearchResponseData result = searchService.search(state, searchToken(updateRequest));

        assertEquals(2, result.encryptedTuples().size());
        assertEquals(
                updateRequest.updateToken().items().get(0).indexEntry().encryptedTuple(),
                result.encryptedTuples().get(0));
        assertEquals(
                updateRequest.updateToken().items().get(1).indexEntry().encryptedTuple(),
                result.encryptedTuples().get(1));
        assertSame(firstShare, result.updateTupleSharesArray()[0]);
        assertSame(secondShare, result.updateTupleSharesArray()[1]);
    }

    @Test
    public void walksAcrossSeparateUpdateBatches() {
        PreparedUpdateRequest firstUpdate = updateTokenService.prepareUpdateRequest(
                MASTER_KEY,
                null,
                new KeywordUpdate("document", Arrays.asList("doc-1"), UpdateOp.ADD));
        PreparedUpdateRequest secondUpdate = updateTokenService.prepareUpdateRequest(
                MASTER_KEY,
                firstUpdate.keywordState(),
                new KeywordUpdate("document", Arrays.asList("doc-2"), UpdateOp.ADD));
        VerifiableShare firstShare = new VerifiableShare();
        VerifiableShare secondShare = new VerifiableShare();
        SSEServerState state = new SSEServerState();
        updateService.update(
                state,
                firstUpdate.updateToken(),
                new VerifiableShare[] {firstShare});
        updateService.update(
                state,
                secondUpdate.updateToken(),
                new VerifiableShare[] {secondShare});

        SearchResponseData result = searchService.search(state, searchToken(secondUpdate));

        assertEquals(2, result.encryptedTuples().size());
        assertEquals(
                firstUpdate.updateToken().items().get(0).indexEntry().encryptedTuple(),
                result.encryptedTuples().get(0));
        assertEquals(
                secondUpdate.updateToken().items().get(0).indexEntry().encryptedTuple(),
                result.encryptedTuples().get(1));
        assertSame(firstShare, result.updateTupleSharesArray()[0]);
        assertSame(secondShare, result.updateTupleSharesArray()[1]);
    }

    @Test(expected = IllegalStateException.class)
    public void rejectsBrokenChainWithMissingEntry() {
        PreparedUpdateRequest updateRequest = prepareTwoUpdates();
        searchService.search(new SSEServerState(), searchToken(updateRequest));
    }

    @Test(expected = IllegalStateException.class)
    public void rejectsBrokenChainWithMissingTupleKeyShare() {
        PreparedUpdateRequest updateRequest = prepareTwoUpdates();
        SSEServerState state = new SSEServerState();
        state.invertedIndexStore().put(
                updateRequest.updateToken().items().get(1).address(),
                updateRequest.updateToken().items().get(1).indexEntry());

        searchService.search(state, searchToken(updateRequest));
    }

    private PreparedUpdateRequest prepareTwoUpdates() {
        return updateTokenService.prepareUpdateRequest(
                MASTER_KEY,
                null,
                new KeywordUpdate(
                        "document",
                        Arrays.asList("doc-1", "doc-2"),
                        UpdateOp.ADD));
    }

    private static SearchToken searchToken(PreparedUpdateRequest updateRequest) {
        return new SearchToken(
                KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document"),
                updateRequest.keywordState().currentToken(),
                updateRequest.keywordState().counter());
    }
}
