package sse.service.server;

import java.util.ArrayDeque;
import java.util.Deque;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.StatePermutation;
import sse.domain.id.IndexAddress;
import sse.domain.id.SearchTokenValue;
import sse.domain.search.SearchResponseData;
import sse.domain.search.SearchToken;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.IndexEntry;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public final class SearchService {

    public SearchResponseData search(SSEServerState state, SearchToken searchToken) {
        if (state == null || searchToken == null) {
            throw new IllegalArgumentException("state and searchToken cannot be null");
        }

        SearchResponseData result = new SearchResponseData();
        Deque<EncryptedUpdateTuple> encryptedTuples = new ArrayDeque<EncryptedUpdateTuple>();
        Deque<VerifiableShare> updateTupleKeys = new ArrayDeque<VerifiableShare>();
        SearchTokenValue currentToken = searchToken.currentToken();
        byte[] keywordH1Key = KeywordKeyDerivation.deriveH1Key(searchToken.keywordKey());
        byte[] keywordH2Key = KeywordKeyDerivation.deriveH2Key(searchToken.keywordKey());

        for (int i = 0; i < searchToken.counter(); i++) {
            IndexAddress address = KeywordKeyDerivation.deriveAddress(keywordH1Key, currentToken);
            IndexEntry indexEntry = state.invertedIndexStore().get(address);
            if (indexEntry == null) {
                throw new IllegalStateException("Missing index entry in search chain");
            }

            VerifiableShare updateTupleKey = state.keyShareStore().getUpdateTupleShare(address);
            if (updateTupleKey == null) {
                throw new IllegalStateException("Missing tuple-key share in search chain");
            }

            encryptedTuples.addFirst(indexEntry.encryptedTuple());
            updateTupleKeys.addFirst(updateTupleKey);

            byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(keywordH2Key, currentToken);
            byte[] ephemeralKeyBytes = KeywordKeyDerivation.unmaskKey(
                    indexEntry.maskedEphemeralKey(),
                    keyMask);
            SecretKey ephemeralKey = new SecretKeySpec(ephemeralKeyBytes, "AES");
            currentToken = StatePermutation.backward(ephemeralKey, currentToken);
        }

        while (!encryptedTuples.isEmpty()) {
            result.add(encryptedTuples.removeFirst(), updateTupleKeys.removeFirst());
        }
        return result;
    }
}
