package sse.domain.setup;

import javax.crypto.SecretKey;

import sse.domain.state.EncryptedKeywordLocationMap;

public final class InitializationMaterial {

    private final SecretKey masterKey;
    private final EncryptedKeywordLocationMap encryptedKeywordLocationMap;

    public InitializationMaterial(SecretKey masterKey,
                                  EncryptedKeywordLocationMap encryptedKeywordLocationMap) {
        if (masterKey == null || encryptedKeywordLocationMap == null) {
            throw new IllegalArgumentException("masterKey and encrypted keyword map cannot be null");
        }
        this.masterKey = masterKey;
        this.encryptedKeywordLocationMap = encryptedKeywordLocationMap;
    }

    public SecretKey masterKey() {
        return masterKey;
    }

    public EncryptedKeywordLocationMap encryptedKeywordLocationMap() {
        return encryptedKeywordLocationMap;
    }
}
