package sse.crypto;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

import sse.domain.id.IndexAddress;
import sse.domain.id.SearchTokenValue;

public class KeywordKeyDerivationTest {

    private static final SecretKey MASTER_KEY = new SecretKeySpec(
            "a fixed master key for testing!!".getBytes(StandardCharsets.UTF_8),
            Prf.ALGORITHM);

    @Test
    public void derivesStableAndSeparatedKeywordKeys() {
        byte[] firstKeywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        byte[] sameKeywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        byte[] otherKeywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "report");

        assertArrayEquals(firstKeywordKey, sameKeywordKey);
        assertFalse(Arrays.equals(firstKeywordKey, otherKeywordKey));

        byte[] h1Key = KeywordKeyDerivation.deriveH1Key(firstKeywordKey);
        byte[] h2Key = KeywordKeyDerivation.deriveH2Key(firstKeywordKey);

        assertEquals(KeywordKeyDerivation.KEY_LENGTH_BYTES, h1Key.length);
        assertEquals(KeywordKeyDerivation.KEY_LENGTH_BYTES, h2Key.length);
        assertFalse(Arrays.equals(h1Key, h2Key));
    }

    @Test
    public void keywordCannotCollideWithKeywordMapKeyLabel() {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "KeywordMapKey");
        byte[] keywordMapKey = KeywordLocationMapEncryption.deriveKey(MASTER_KEY).getEncoded();

        assertFalse(Arrays.equals(keywordKey, keywordMapKey));
    }

    @Test
    public void derivesStableAddressAndSixteenByteMask() {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        byte[] h1Key = KeywordKeyDerivation.deriveH1Key(keywordKey);
        byte[] h2Key = KeywordKeyDerivation.deriveH2Key(keywordKey);
        SearchTokenValue state = fixedState();

        IndexAddress firstAddress = KeywordKeyDerivation.deriveAddress(h1Key, state);
        IndexAddress sameAddress = KeywordKeyDerivation.deriveAddress(h1Key, state);
        byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(h2Key, state);

        assertEquals(firstAddress, sameAddress);
        assertEquals(StatePermutation.KEY_LENGTH_BYTES, keyMask.length);
    }

    @Test
    public void unmaskingRecoversEphemeralKey() {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        byte[] h2Key = KeywordKeyDerivation.deriveH2Key(keywordKey);
        byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(h2Key, fixedState());
        byte[] ephemeralKey = "16-byte AES key!".getBytes(StandardCharsets.UTF_8);

        byte[] maskedKey = KeywordKeyDerivation.maskKey(ephemeralKey, keyMask);

        assertFalse(Arrays.equals(ephemeralKey, maskedKey));
        assertArrayEquals(ephemeralKey, KeywordKeyDerivation.unmaskKey(maskedKey, keyMask));
    }

    private static SearchTokenValue fixedState() {
        return new SearchTokenValue("16-byte state!!!".getBytes(StandardCharsets.UTF_8));
    }
}
