package sse.crypto;

import java.io.IOException;
import java.security.InvalidAlgorithmParameterException;
import java.security.InvalidKeyException;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;

import javax.crypto.BadPaddingException;
import javax.crypto.Cipher;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SealedObject;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

import sse.domain.update.UpdateTuple;

public final class TupleEncryption {

    private static final String CIPHER_ALGORITHM = "AES/GCM/NoPadding";
    private static final String KEY_ALGORITHM = "AES";
    private static final int GCM_IV_LENGTH = 12; // 96 bits
    private static final int GCM_TAG_LENGTH = 128;
    private static final int AES_KEY_SIZE = 256;
    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private TupleEncryption() {
        // Private constructor to prevent instantiation
    }

    public static SecretKey generateRandomKey() {
        byte[] key = new byte[AES_KEY_SIZE / Byte.SIZE];
        SECURE_RANDOM.nextBytes(key);
        return new SecretKeySpec(key, KEY_ALGORITHM);
    }

    public static byte[] generateIv() {
        byte[] iv = new byte[GCM_IV_LENGTH];
        SECURE_RANDOM.nextBytes(iv);
        return iv;
    }

    public static Cipher createCipher() {
        try {
            return Cipher.getInstance(CIPHER_ALGORITHM);
        } catch (NoSuchAlgorithmException | NoSuchPaddingException e) {
            throw new IllegalStateException("AES-GCM tuple cipher initialization failed", e);
        }
    }

    public static SealedObject encryptTuple(Cipher cipher, SecretKey key, byte[] iv, UpdateTuple tuple)
            throws InvalidKeyException, InvalidAlgorithmParameterException, IOException, IllegalBlockSizeException {
        if (cipher == null) {
            throw new IllegalArgumentException("cipher cannot be null");
        }
        cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH, iv));
        return new SealedObject(tuple, cipher);
    }

    public static UpdateTuple decryptTuple(Cipher cipher, SecretKey key, byte[] iv, SealedObject sealedObject)
            throws InvalidAlgorithmParameterException, InvalidKeyException, ClassNotFoundException,
            BadPaddingException, IllegalBlockSizeException, IOException {
        if (cipher == null) {
            throw new IllegalArgumentException("cipher cannot be null");
        }
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH, iv));
        return (UpdateTuple) sealedObject.getObject(cipher);
    }
}
