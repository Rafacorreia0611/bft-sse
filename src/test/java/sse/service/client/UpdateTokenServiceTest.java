package sse.service.client;

import static org.junit.Assert.assertEquals;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.Prf;
import sse.crypto.StatePermutation;
import sse.crypto.TupleEncryption;
import sse.domain.id.SearchTokenValue;
import sse.domain.state.KeywordState;
import sse.domain.update.IndexEntry;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateTokenItem;
import sse.domain.update.UpdateTuple;

public class UpdateTokenServiceTest {

    private static final SecretKey MASTER_KEY = new SecretKeySpec(
            "a fixed master key for testing!!".getBytes(StandardCharsets.UTF_8),
            Prf.ALGORITHM);

    private final UpdateTokenService service = new UpdateTokenService();

    @Test
    public void createsOneLinkedIndexEntryPerDocument() throws Exception {
        KeywordUpdate update = new KeywordUpdate(
                "document",
                Arrays.asList("doc-1", "doc-2"),
                UpdateOp.ADD);

        PreparedUpdateRequest request = service.prepareUpdateRequest(MASTER_KEY, null, update);

        assertEquals(2, request.updateToken().items().size());
        assertEquals(2, request.tupleKeys().size());
        assertEquals(2, request.keywordState().counter());

        verifyChain(request, "document");
        verifyEncryptedTuples(request, Arrays.asList("doc-1", "doc-2"), UpdateOp.ADD);
    }

    @Test
    public void advancesExistingKeywordState() {
        SearchTokenValue previousToken = new SearchTokenValue(
                "previous state!!".getBytes(StandardCharsets.UTF_8));
        KeywordState previousState = new KeywordState(previousToken, 7);
        KeywordUpdate update = new KeywordUpdate(
                "document",
                Arrays.asList("doc-8"),
                UpdateOp.DEL);

        PreparedUpdateRequest request =
                service.prepareUpdateRequest(MASTER_KEY, previousState, update);

        assertEquals(8, request.keywordState().counter());
        assertEquals(previousToken, recoverPreviousToken(
                request.updateToken().items().get(0),
                request.keywordState().currentToken(),
                "document"));
    }

    private static void verifyChain(PreparedUpdateRequest request, String keyword) {
        SearchTokenValue currentToken = request.keywordState().currentToken();
        List<UpdateTokenItem> items = request.updateToken().items();
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, keyword);
        byte[] h1Key = KeywordKeyDerivation.deriveH1Key(keywordKey);

        for (int i = items.size() - 1; i >= 0; i--) {
            UpdateTokenItem item = items.get(i);
            assertEquals(
                    KeywordKeyDerivation.deriveAddress(h1Key, currentToken),
                    item.address());
            currentToken = recoverPreviousToken(item, currentToken, keyword);
        }
    }

    private static SearchTokenValue recoverPreviousToken(UpdateTokenItem item,
                                                          SearchTokenValue currentToken,
                                                          String keyword) {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, keyword);
        byte[] h2Key = KeywordKeyDerivation.deriveH2Key(keywordKey);
        byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(h2Key, currentToken);
        byte[] ephemeralKey = KeywordKeyDerivation.unmaskKey(
                item.indexEntry().maskedEphemeralKey(),
                keyMask);

        return StatePermutation.backward(
                new SecretKeySpec(ephemeralKey, "AES"),
                currentToken);
    }

    private static void verifyEncryptedTuples(PreparedUpdateRequest request,
                                               List<String> expectedDocIds,
                                               UpdateOp expectedOperation) throws Exception {
        for (int i = 0; i < expectedDocIds.size(); i++) {
            IndexEntry entry = request.updateToken().items().get(i).indexEntry();
            UpdateTuple tuple = TupleEncryption.decryptTuple(
                    request.tupleKeys().get(i),
                    entry.encryptedTuple().iv(),
                    entry.encryptedTuple().encryptedTuple());

            assertEquals(expectedDocIds.get(i), tuple.docId());
            assertEquals(expectedOperation, tuple.op());
        }
    }
}
