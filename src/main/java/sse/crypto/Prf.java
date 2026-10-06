package sse.crypto;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;

import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

public final class Prf {

    public static final String ALGORITHM = "HmacSHA256";

    private Prf() {
        // Utility class, prevent instantiation
    }

    private static byte[] prf(SecretKey key, byte[] input) {
        return prf(createMac(key), input);
    }

    public static byte[] prf(SecretKey key, String input) {
        return prf(key, input.getBytes(StandardCharsets.UTF_8));
    }

    private static byte[] prf(byte[] keyBytes, byte[] input) {
        return prf(new SecretKeySpec(keyBytes, ALGORITHM), input);
    }

    public static byte[] prf(byte[] keyBytes, String input) {
        return prf(keyBytes, input.getBytes(StandardCharsets.UTF_8));
    }

    public static Mac createMac(byte[] keyBytes) {
        if (keyBytes == null) {
            throw new IllegalArgumentException("keyBytes cannot be null");
        }
        return createMac(new SecretKeySpec(keyBytes, ALGORITHM));
    }

    public static byte[] prf(Mac mac, byte[] input) {
        if (mac == null || input == null) {
            throw new IllegalArgumentException("mac and input cannot be null");
        }
        return mac.doFinal(input);
    }

    private static Mac createMac(SecretKey key) {
        if (key == null) {
            throw new IllegalArgumentException("key cannot be null");
        }
        try {
            Mac mac = Mac.getInstance(ALGORITHM);
            mac.init(key);
            return mac;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("HMAC-SHA256 PRF initialization failed", e);
        }
    }

}
