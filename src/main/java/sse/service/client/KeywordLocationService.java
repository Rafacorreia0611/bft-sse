package sse.service.client;

import javax.crypto.SecretKey;

import sse.crypto.KeywordLocationMapEncryption;
import sse.domain.state.KeywordLocationMap;
import sse.domain.state.State;
import sse.vocabulary.KeywordNormalizer;
import sse.vocabulary.LuceneKeywordNormalizer;

public final class KeywordLocationService {

    private final KeywordNormalizer keywordNormalizer;

    public KeywordLocationService() {
        this(new LuceneKeywordNormalizer());
    }

    public KeywordLocationService(KeywordNormalizer keywordNormalizer) {
        if (keywordNormalizer == null) {
            throw new IllegalArgumentException("keywordNormalizer cannot be null");
        }
        this.keywordNormalizer = keywordNormalizer;
    }

    public String normalizeKeyword(String rawKeyword) {
        return keywordNormalizer.normalize(rawKeyword);
    }

    public Integer resolveLocation(KeywordLocationMap locationMap, String normalizedKeyword) {
        if (locationMap == null) {
            throw new IllegalArgumentException("locationMap cannot be null");
        }
        if (normalizedKeyword == null || normalizedKeyword.trim().isEmpty()) {
            throw new IllegalArgumentException("normalizedKeyword cannot be null or blank");
        }
        return validateAddress(locationMap.addressOf(normalizedKeyword));
    }

    public KeywordLocationMap decryptLocationMap(SecretKey masterKey, State state) {
        if (masterKey == null || state == null) {
            throw new IllegalArgumentException("masterKey and state cannot be null");
        }
        if (state.encryptedKeywordLocationMap() == null) {
            throw new IllegalStateException("State is missing encrypted keyword location map");
        }
        SecretKey keywordLocationMapKey = KeywordLocationMapEncryption.deriveKey(masterKey);
        return KeywordLocationMapEncryption.decrypt(keywordLocationMapKey, state.encryptedKeywordLocationMap());
    }

    private Integer validateAddress(Integer address) {
        if (address != null && address.intValue() < 0) {
            throw new IllegalStateException("Resolved ORAM address cannot be negative: " + address);
        }
        return address;
    }
}
