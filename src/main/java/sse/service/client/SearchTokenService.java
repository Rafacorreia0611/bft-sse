package sse.service.client;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.TupleEncryption;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.state.KeywordState;
import sse.domain.search.SearchToken;
import sse.domain.update.UpdateTuple;

public final class SearchTokenService {

    public SearchToken generateSearchToken(SecretKey masterKey, KeywordState keywordState, String keyword) {
        if (masterKey == null || keyword == null) {
            throw new IllegalArgumentException("masterKey and keyword cannot be null");
        }
        if (keywordState == null) {
            return null;
        }

        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(masterKey, keyword);
        return new SearchToken(keywordKey, keywordState.currentToken(), keywordState.counter());
    }

    public List<String> extractAddedDocIds(Map<EncryptedUpdateTuple, SecretKey> updates) {
        if (updates == null) {
            throw new IllegalArgumentException("updates cannot be null");
        }

        Set<String> activeDocIds = new LinkedHashSet<>();
        Cipher tupleCipher = TupleEncryption.createCipher();
        for (Map.Entry<EncryptedUpdateTuple, SecretKey> entry : updates.entrySet()) {
            if (entry == null || entry.getKey() == null || entry.getValue() == null) {
                continue;
            }

            UpdateTuple update;
            try {
                update = TupleEncryption.decryptTuple(
                        tupleCipher,
                        entry.getValue(),
                        entry.getKey().iv(),
                        entry.getKey().encryptedTuple());
            } catch (Exception e) {
                throw new IllegalStateException("Failed to decrypt update tuple", e);
            }

            switch (update.op()) {
                case ADD:
                    activeDocIds.add(update.docId());
                    break;
                case DEL:
                    activeDocIds.remove(update.docId());
                    break;
                default:
                    throw new IllegalStateException("Unknown update operation: " + update.op());
            }
        }
        return new ArrayList<>(activeDocIds);
    }
}
