package sse.service.client;

import java.io.IOException;
import java.security.InvalidAlgorithmParameterException;
import java.security.InvalidKeyException;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;

import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.SecretKey;

import sse.crypto.KeywordKeyDerivation;
import sse.crypto.StatePermutation;
import sse.crypto.TupleEncryption;
import sse.domain.id.IndexAddress;
import sse.domain.id.SearchTokenValue;
import sse.domain.state.KeywordState;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.IndexEntry;
import sse.domain.update.KeywordUpdate;
import sse.domain.update.PreparedUpdateRequest;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateToken;
import sse.domain.update.UpdateTokenItem;
import sse.domain.update.UpdateTuple;

public final class UpdateTokenService {

    private SecretKey generateTupleSecretKey() {
        return TupleEncryption.generateRandomKey();
    }

    private byte[] generateTupleIv() {
        return TupleEncryption.generateIv();
    }

    private EncryptedUpdateTuple encryptUpdateTuple(SecretKey key, byte[] iv, UpdateTuple tuple)
            throws NoSuchAlgorithmException, NoSuchPaddingException, InvalidKeyException,
            InvalidAlgorithmParameterException, IOException, IllegalBlockSizeException {
        return new EncryptedUpdateTuple(TupleEncryption.encryptTuple(key, iv, tuple), iv);
    }

    private EncryptedUpdateTuple generateEncryptedUpdateTuple(String docId, UpdateOp operation, SecretKey encryptionKey) {
        if (operation == null) {
            throw new IllegalArgumentException("operation cannot be null");
        }
        byte[] iv = generateTupleIv();
        try {
            return encryptUpdateTuple(encryptionKey, iv, new UpdateTuple(docId, operation));
        } catch (Exception e) {
            throw new RuntimeException("Error encrypting update tuple", e);
        }
    }

    public PreparedUpdateRequest prepareUpdateRequest(SecretKey masterKey, KeywordState keywordState,
                                                      KeywordUpdate update) {
        if (masterKey == null || update == null) {
            throw new IllegalArgumentException("masterKey and update cannot be null");
        }

        List<UpdateTokenItem> items = new ArrayList<UpdateTokenItem>();
        List<SecretKey> tupleKeys = new ArrayList<SecretKey>();

        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(masterKey, update.keyword());
        byte[] keywordH1Key = KeywordKeyDerivation.deriveH1Key(keywordKey);
        byte[] keywordH2Key = KeywordKeyDerivation.deriveH2Key(keywordKey);

        SearchTokenValue currentToken = keywordState == null
                ? StatePermutation.generateRandomState()
                : keywordState.currentToken();
        int currentCounter = keywordState == null ? 0 : keywordState.counter();

        for (String docId : update.docIds()) {
            SecretKey tupleKey = generateTupleSecretKey();
            EncryptedUpdateTuple encryptedTuple =
                    generateEncryptedUpdateTuple(docId, update.operation(), tupleKey);

            SecretKey ephemeralKey = StatePermutation.generateKey();
            SearchTokenValue nextToken = StatePermutation.forward(ephemeralKey, currentToken);
            IndexAddress address = KeywordKeyDerivation.deriveAddress(keywordH1Key, nextToken);
            byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(keywordH2Key, nextToken);
            byte[] maskedEphemeralKey = KeywordKeyDerivation.maskKey(
                    ephemeralKey.getEncoded(),
                    keyMask);

            IndexEntry indexEntry = new IndexEntry(encryptedTuple, maskedEphemeralKey);
            items.add(new UpdateTokenItem(address, indexEntry));
            tupleKeys.add(tupleKey);

            currentToken = nextToken;
            currentCounter++;
        }

        KeywordState nextKeywordState = new KeywordState(currentToken, currentCounter);
        return new PreparedUpdateRequest(new UpdateToken(items), tupleKeys, nextKeywordState);
    }
}
