package sse.facade;

import java.security.NoSuchAlgorithmException;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

import sse.crypto.KeywordLocationMapEncryption;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.setup.InitializationMaterial;
import sse.domain.setup.PreparedInitialization;
import sse.domain.state.KeywordLocationMap;
import sse.domain.state.KeywordState;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.search.SearchToken;
import sse.domain.state.State;
import sse.service.client.KeywordLocationService;
import sse.service.client.SearchTokenService;
import sse.service.client.UpdateTokenService;
import sse.vocabulary.LuceneKeywordNormalizer;
import sse.vocabulary.VocabularyLoader;

public final class SSEClientFacade {

    private final SearchTokenService searchTokenService;
    private final UpdateTokenService updateTokenService;
    private final KeywordLocationService keywordLocationService;

    public SSEClientFacade() {
        this.searchTokenService = new SearchTokenService();
        this.updateTokenService = new UpdateTokenService();
        this.keywordLocationService = new KeywordLocationService();
    }

    public PreparedInitialization prepareInitialization(Path vocabularyPath) {
        if (vocabularyPath == null) {
            throw new IllegalArgumentException("vocabularyPath cannot be null");
        }

        SecretKey masterKey = generateMasterKey();

        KeywordLocationMap keywordLocationMap = generateKeywordLocationMap(vocabularyPath);
        EncryptedKeywordLocationMap encryptedKeywordLocationMap =
                encryptKeywordLocationMap(masterKey, keywordLocationMap);

        return new PreparedInitialization(
                new InitializationMaterial(
                        masterKey,
                        encryptedKeywordLocationMap
                ),
                keywordLocationMap.oramCapacity()
        );
    }

    public SearchToken generateSearchToken(SecretKey masterKey, KeywordState keywordState, String keyword) {
        return searchTokenService.generateSearchToken(masterKey, keywordState, keyword);
    }

    public String normalizeKeyword(String rawKeyword) {
        return keywordLocationService.normalizeKeyword(rawKeyword);
    }

    public Integer resolveKeywordLocation(SecretKey masterKey, State state, String normalizedKeyword) {
        return keywordLocationService.resolveLocation(masterKey, state, normalizedKeyword);
    }

    public PreparedUpdateRequest prepareUpdateRequest(SecretKey masterKey, KeywordState keywordState,
                                                      KeywordUpdate update) {
        return updateTokenService.prepareUpdateRequest(
                masterKey,
                keywordState,
                update
        );
    }

    public List<String> extractAddedDocIds(Map<EncryptedUpdateTuple, SecretKey> updates) {
        return searchTokenService.extractAddedDocIds(updates);
    }

    private SecretKey generateMasterKey() {
        KeyGenerator keyGen;
        try {
            keyGen = KeyGenerator.getInstance("HmacSHA256");
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("HmacSHA256 algorithm not available for master key", e);
        }
        keyGen.init(256);
        return keyGen.generateKey();
    }

    private KeywordLocationMap generateKeywordLocationMap(Path vocabularyPath) {
        VocabularyLoader vocabularyLoader = new VocabularyLoader(new LuceneKeywordNormalizer());
        List<String> keywords = vocabularyLoader.load(vocabularyPath);
        return KeywordLocationMap.build(keywords);
    }

    private EncryptedKeywordLocationMap encryptKeywordLocationMap(SecretKey masterKey,
                                                                  KeywordLocationMap keywordLocationMap) {
        SecretKey keywordMapKey = KeywordLocationMapEncryption.deriveKey(masterKey);
        return KeywordLocationMapEncryption.encrypt(
                keywordMapKey,
                KeywordLocationMapEncryption.generateIv(),
                keywordLocationMap
        );
    }
}
