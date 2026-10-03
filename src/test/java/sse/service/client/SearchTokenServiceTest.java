package sse.service.client;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.nio.charset.StandardCharsets;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.Prf;
import sse.domain.id.SearchTokenValue;
import sse.domain.search.SearchToken;
import sse.domain.state.KeywordState;

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
}
