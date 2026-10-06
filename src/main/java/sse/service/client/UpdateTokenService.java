package sse.service.client;

import java.util.ArrayList;
import java.util.List;

import javax.crypto.Cipher;
import javax.crypto.Mac;
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

    private EncryptedUpdateTuple encryptUpdateTuple(Cipher cipher, String docId,
                                                     UpdateOp operation, SecretKey key) {
        if (operation == null) {
            throw new IllegalArgumentException("operation cannot be null");
        }
        byte[] iv = TupleEncryption.generateIv();
        try {
            return new EncryptedUpdateTuple(
                    TupleEncryption.encryptTuple(
                            cipher,
                            key,
                            iv,
                            new UpdateTuple(docId, operation)),
                    iv);
        } catch (Exception e) {
            throw new RuntimeException("Error encrypting update tuple", e);
        }
    }

    public PreparedUpdateRequest prepareUpdateRequest(SecretKey masterKey, KeywordState keywordState,
                                                      KeywordUpdate update) {
        if (masterKey == null || update == null) {
            throw new IllegalArgumentException("masterKey and update cannot be null");
        }

        List<UpdateTokenItem> items = new ArrayList<UpdateTokenItem>(update.docIds().size());
        List<SecretKey> tupleKeys = new ArrayList<SecretKey>(update.docIds().size());

        byte[] keywordKey = KeywordKeyDerivation.deriveKeywordKey(masterKey, update.keyword());
        Mac addressMac = KeywordKeyDerivation.createAddressMac(keywordKey);
        Mac keyMaskMac = KeywordKeyDerivation.createKeyMaskMac(keywordKey);
        Cipher stateCipher = StatePermutation.createCipher();
        Cipher tupleCipher = TupleEncryption.createCipher();

        SearchTokenValue currentToken = keywordState == null
                ? StatePermutation.generateRandomState()
                : keywordState.currentToken();
        int currentCounter = keywordState == null ? 0 : keywordState.counter();

        for (String docId : update.docIds()) {
            SecretKey tupleKey = TupleEncryption.generateRandomKey();
            EncryptedUpdateTuple encryptedTuple =
                    encryptUpdateTuple(tupleCipher, docId, update.operation(), tupleKey);

            SecretKey ephemeralKey = StatePermutation.generateKey();
            SearchTokenValue nextToken = StatePermutation.forward(
                    stateCipher,
                    ephemeralKey,
                    currentToken);
            IndexAddress address = KeywordKeyDerivation.deriveAddress(addressMac, nextToken);
            byte[] keyMask = KeywordKeyDerivation.deriveKeyMask(keyMaskMac, nextToken);
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
