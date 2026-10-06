package sse.crypto;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import javax.crypto.Mac;
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
        assertEquals(KeywordKeyDerivation.KEY_LENGTH_BYTES, firstKeywordKey.length);
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
        Mac addressMac = KeywordKeyDerivation.createAddressMac(keywordKey);
        Mac sameAddressMac = KeywordKeyDerivation.createAddressMac(keywordKey);
        Mac keyMaskMac = KeywordKeyDerivation.createKeyMaskMac(keywordKey);
        SearchTokenValue state = fixedState();

        IndexAddress firstAddress = KeywordKeyDerivation.deriveAddress(addressMac, state);
        IndexAddress sameAddress = KeywordKeyDerivation.deriveAddress(sameAddressMac, state);
        byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(keyMaskMac, state);

        assertEquals(firstAddress, sameAddress);
        assertEquals(StatePermutation.KEY_LENGTH_BYTES, keyMask.length);
        assertFalse(Arrays.equals(
                Arrays.copyOf(firstAddress.value(), StatePermutation.KEY_LENGTH_BYTES),
                keyMask));
    }

    @Test
    public void reusableMacsRemainStableAcrossStates() {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        Mac addressMac = KeywordKeyDerivation.createAddressMac(keywordKey);
        Mac sameAddressMac = KeywordKeyDerivation.createAddressMac(keywordKey);
        Mac keyMaskMac = KeywordKeyDerivation.createKeyMaskMac(keywordKey);
        Mac sameKeyMaskMac = KeywordKeyDerivation.createKeyMaskMac(keywordKey);
        SearchTokenValue[] states = {
                fixedState(),
                new SearchTokenValue("another state!!!".getBytes(StandardCharsets.UTF_8))
        };

        for (SearchTokenValue state : states) {
            assertEquals(
                    KeywordKeyDerivation.deriveAddress(sameAddressMac, state),
                    KeywordKeyDerivation.deriveAddress(addressMac, state));
            assertArrayEquals(
                    KeywordKeyDerivation.deriveKeyMask(sameKeyMaskMac, state),
                    KeywordKeyDerivation.deriveKeyMask(keyMaskMac, state));
        }
    }

    @Test
    public void unmaskingRecoversEphemeralKey() {
        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(MASTER_KEY, "document");
        Mac keyMaskMac = KeywordKeyDerivation.createKeyMaskMac(keywordKey);
        byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(keyMaskMac, fixedState());
        byte[] ephemeralKey = "16-byte AES key!".getBytes(StandardCharsets.UTF_8);

        byte[] maskedKey = KeywordKeyDerivation.maskKey(ephemeralKey, keyMask);

        assertFalse(Arrays.equals(ephemeralKey, maskedKey));
        assertArrayEquals(ephemeralKey, KeywordKeyDerivation.unmaskKey(maskedKey, keyMask));
    }

    private static SearchTokenValue fixedState() {
        return new SearchTokenValue("16-byte state!!!".getBytes(StandardCharsets.UTF_8));
    }
}
