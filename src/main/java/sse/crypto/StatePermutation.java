package sse.crypto;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import sse.domain.id.SearchTokenValue;

public final class StatePermutation {

    public static final int STATE_LENGTH_BYTES = 16;
    public static final int KEY_LENGTH_BYTES = 16;

    private static final String KEY_ALGORITHM = "AES";
    private static final String CIPHER_ALGORITHM = "AES/ECB/NoPadding";
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private StatePermutation() {
        // Utility class, prevent instantiation
    }

    public static SearchTokenValue generateRandomState() {
        byte[] state = new byte[STATE_LENGTH_BYTES];
        SECURE_RANDOM.nextBytes(state);
        return new SearchTokenValue(state);
    }

    public static SecretKey generateKey() {
        byte[] key = new byte[KEY_LENGTH_BYTES];
        SECURE_RANDOM.nextBytes(key);
        return new SecretKeySpec(key, KEY_ALGORITHM);
    }

    public static SearchTokenValue forward(SecretKey key, SearchTokenValue previousState) {
        return apply(Cipher.ENCRYPT_MODE, key, previousState);
    }

    public static SearchTokenValue backward(SecretKey key, SearchTokenValue currentState) {
        return apply(Cipher.DECRYPT_MODE, key, currentState);
    }

    private static SearchTokenValue apply(int mode, SecretKey key, SearchTokenValue state) {
        validateKey(key);
        validateState(state);

        try {
            Cipher cipher = Cipher.getInstance(CIPHER_ALGORITHM);
            cipher.init(mode, key);
            return new SearchTokenValue(cipher.doFinal(state.value()));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("AES state permutation failed", e);
        }
    }

    private static void validateKey(SecretKey key) {
        if (key == null) {
            throw new IllegalArgumentException("key cannot be null");
        }
        byte[] encodedKey = key.getEncoded();
        if (encodedKey == null || encodedKey.length != KEY_LENGTH_BYTES) {
            throw new IllegalArgumentException("key must be exactly " + KEY_LENGTH_BYTES + " bytes");
        }
    }

    private static void validateState(SearchTokenValue state) {
        if (state == null) {
            throw new IllegalArgumentException("state cannot be null");
        }
        if (state.value().length != STATE_LENGTH_BYTES) {
            throw new IllegalArgumentException("state must be exactly " + STATE_LENGTH_BYTES + " bytes");
        }
    }
}
