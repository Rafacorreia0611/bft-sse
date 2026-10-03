package sse.domain.search;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

import sse.domain.id.SearchTokenValue;

public class SearchTokenTest {

    @Test
    public void preservesAndProtectsTokenData() {
        byte[] keywordKey = keywordKey();
        SearchTokenValue currentToken = currentToken();
        SearchToken searchToken = new SearchToken(keywordKey, currentToken, 3);

        keywordKey[0] = 99;
        byte[] returnedKeywordKey = searchToken.keywordKey();
        returnedKeywordKey[1] = 99;

        assertArrayEquals(keywordKey(), searchToken.keywordKey());
        assertEquals(currentToken, searchToken.currentToken());
        assertEquals(3, searchToken.counter());
    }

    @Test
    public void survivesSerializationRoundTrip() {
        SearchToken searchToken = new SearchToken(keywordKey(), currentToken(), 3);

        SearchToken restored = SearchToken.deserialize(searchToken.serialize());

        assertEquals(searchToken, restored);
        assertEquals(searchToken.hashCode(), restored.hashCode());
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsKeywordKeyWithWrongLength() {
        new SearchToken(new byte[31], currentToken(), 1);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsStateWithWrongLength() {
        new SearchToken(keywordKey(), new SearchTokenValue(new byte[15]), 1);
    }

    private static byte[] keywordKey() {
        byte[] keywordKey = new byte[32];
        for (int i = 0; i < keywordKey.length; i++) {
            keywordKey[i] = (byte) i;
        }
        return keywordKey;
    }

    private static SearchTokenValue currentToken() {
        return new SearchTokenValue(new byte[16]);
    }
}
