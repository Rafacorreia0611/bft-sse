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

    public static Cipher createCipher() {
        try {
            return Cipher.getInstance(CIPHER_ALGORITHM);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("AES state cipher initialization failed", e);
        }
    }

    public static SearchTokenValue forward(Cipher cipher, SecretKey key,
                                           SearchTokenValue previousState) {
        return apply(cipher, Cipher.ENCRYPT_MODE, key, previousState);
    }

    public static SearchTokenValue backward(Cipher cipher, SecretKey key,
                                            SearchTokenValue currentState) {
        return apply(cipher, Cipher.DECRYPT_MODE, key, currentState);
    }

    private static SearchTokenValue apply(Cipher cipher, int mode, SecretKey key,
                                          SearchTokenValue state) {
        if (cipher == null) {
            throw new IllegalArgumentException("cipher cannot be null");
        }
        validateKey(key);
        validateState(state);

        try {
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
