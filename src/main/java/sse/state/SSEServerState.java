package sse.state;

import sse.domain.state.EncryptedKeywordLocationMap;

public final class SSEServerState {

    private EncryptedKeywordLocationMap encryptedKeywordLocationMap;
    private final InvertedIndexStore invertedIndexStore;
    private final KeyShareStore keyShareStore;

    public SSEServerState() {
        this.encryptedKeywordLocationMap = null;
        this.invertedIndexStore = new InvertedIndexStore();
        this.keyShareStore = new KeyShareStore();
    }

    public EncryptedKeywordLocationMap encryptedKeywordLocationMap() {
        return encryptedKeywordLocationMap;
    }

    public void setEncryptedKeywordLocationMap(EncryptedKeywordLocationMap encryptedKeywordLocationMap) {
        this.encryptedKeywordLocationMap = encryptedKeywordLocationMap;
    }

    public boolean isInitialized() {
        return encryptedKeywordLocationMap != null
                && keyShareStore.hasMasterKeyShare();
    }

    public InvertedIndexStore invertedIndexStore() {
        return invertedIndexStore;
    }

    public KeyShareStore keyShareStore() {
        return keyShareStore;
    }
}
