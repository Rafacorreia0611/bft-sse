package sse.crypto;

import java.util.Arrays;

import javax.crypto.SecretKey;

import sse.domain.id.IndexAddress;
import sse.domain.id.SearchTokenValue;

public final class KeywordKeyDerivation {

    public static final int KEY_LENGTH_BYTES = 32;

    private static final String KEYWORD_KEY_LABEL = "KeywordKey";
    private static final String H1_KEY_LABEL = "H1Key";
    private static final String H2_KEY_LABEL = "H2Key";

    private KeywordKeyDerivation() {
        // Utility class, prevent instantiation
    }

    public static byte[] deriveKeywordKey(SecretKey masterKey, String keyword) {
        if (masterKey == null) {
            throw new IllegalArgumentException("masterKey cannot be null");
        }
        if (keyword == null || keyword.isEmpty()) {
            throw new IllegalArgumentException("keyword cannot be null or empty");
        }

        byte[] keywordRootKey = Prf.prf(masterKey, KEYWORD_KEY_LABEL);
        return Prf.prf(keywordRootKey, keyword);
    }

    public static byte[] deriveH1Key(byte[] keywordKey) {
        validateDerivedKey(keywordKey, "keywordKey");
        return Prf.prf(keywordKey, H1_KEY_LABEL);
    }

    public static byte[] deriveH2Key(byte[] keywordKey) {
        validateDerivedKey(keywordKey, "keywordKey");
        return Prf.prf(keywordKey, H2_KEY_LABEL);
    }

    public static IndexAddress deriveAddress(byte[] keywordH1Key, SearchTokenValue state) {
        validateDerivedKey(keywordH1Key, "keywordH1Key");
        validateState(state);
        return new IndexAddress(Prf.prf(keywordH1Key, state.value()));
    }

    public static byte[] deriveKeyMask(byte[] keywordH2Key, SearchTokenValue state) {
        validateDerivedKey(keywordH2Key, "keywordH2Key");
        validateState(state);
        return Arrays.copyOf(
                Prf.prf(keywordH2Key, state.value()),
                StatePermutation.KEY_LENGTH_BYTES);
    }

    public static byte[] maskKey(byte[] ephemeralKey, byte[] keyMask) {
        validateEphemeralKey(ephemeralKey, "ephemeralKey");
        validateEphemeralKey(keyMask, "keyMask");

        byte[] maskedKey = new byte[StatePermutation.KEY_LENGTH_BYTES];
        for (int i = 0; i < maskedKey.length; i++) {
            maskedKey[i] = (byte) (ephemeralKey[i] ^ keyMask[i]);
        }
        return maskedKey;
    }

    public static byte[] unmaskKey(byte[] maskedKey, byte[] keyMask) {
        validateEphemeralKey(maskedKey, "maskedKey");
        return maskKey(maskedKey, keyMask);
    }

    private static void validateDerivedKey(byte[] key, String name) {
        if (key == null || key.length != KEY_LENGTH_BYTES) {
            throw new IllegalArgumentException(name + " must be exactly " + KEY_LENGTH_BYTES + " bytes");
        }
    }

    private static void validateEphemeralKey(byte[] key, String name) {
        if (key == null || key.length != StatePermutation.KEY_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    name + " must be exactly " + StatePermutation.KEY_LENGTH_BYTES + " bytes");
        }
    }

    private static void validateState(SearchTokenValue state) {
        if (state == null || state.value().length != StatePermutation.STATE_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    "state must be exactly " + StatePermutation.STATE_LENGTH_BYTES + " bytes");
        }
    }
}
