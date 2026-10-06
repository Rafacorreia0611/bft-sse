package sse.service.client;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.Prf;
import sse.crypto.TupleEncryption;
import sse.domain.id.SearchTokenValue;
import sse.domain.search.SearchToken;
import sse.domain.state.KeywordState;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateTuple;

public class SearchTokenServiceTest {

    private static final SecretKey MASTER_KEY = new SecretKeySpec(
            "a fixed master key for testing!!".getBytes(StandardCharsets.UTF_8),
            Prf.ALGORITHM);

    private final SearchTokenService service = new SearchTokenService();

    @Test
    public void derivesKeywordKeyAndPreservesKeywordState() {
        KeywordState keywordState = new KeywordState(
                new SearchTokenValue("current state!!!".getBytes(StandardCharsets.UTF_8)),
                7);

        SearchToken searchToken =
                service.generateSearchToken(MASTER_KEY, keywordState, "document");

        assertArrayEquals(
                KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document"),
                searchToken.keywordKey());
        assertEquals(keywordState.currentToken(), searchToken.currentToken());
        assertEquals(keywordState.counter(), searchToken.counter());
    }

    @Test
    public void returnsNullWhenKeywordHasNoState() {
        assertNull(service.generateSearchToken(MASTER_KEY, null, "document"));
    }

    @Test
    public void processesMultipleEncryptedUpdatesWithReusableCipher() throws Exception {
        Map<EncryptedUpdateTuple, SecretKey> updates =
                new LinkedHashMap<EncryptedUpdateTuple, SecretKey>();
        addEncryptedUpdate(updates, "doc-1", UpdateOp.ADD);
        addEncryptedUpdate(updates, "doc-2", UpdateOp.ADD);
        addEncryptedUpdate(updates, "doc-1", UpdateOp.DEL);

        List<String> result = service.extractAddedDocIds(updates);

        assertEquals(Arrays.asList("doc-2"), result);
    }

    private static void addEncryptedUpdate(Map<EncryptedUpdateTuple, SecretKey> updates,
                                           String docId, UpdateOp operation) throws Exception {
        SecretKey key = TupleEncryption.generateRandomKey();
        byte[] iv = TupleEncryption.generateIv();
        EncryptedUpdateTuple encryptedTuple = new EncryptedUpdateTuple(
                TupleEncryption.encryptTuple(
                        TupleEncryption.createCipher(),
                        key,
                        iv,
                        new UpdateTuple(docId, operation)),
                iv);
        updates.put(encryptedTuple, key);
    }
}
