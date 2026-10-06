package sse.service.server;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

import sse.domain.id.IndexAddress;
import sse.domain.update.UpdateToken;
import sse.domain.update.UpdateTokenItem;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public final class UpdateService {

    public void update(SSEServerState state, UpdateToken updateToken, VerifiableShare[] updateTupleKeyShares) {
        if (state == null || updateToken == null || updateTupleKeyShares == null) {
            throw new IllegalArgumentException(
                    "state, updateToken and updateTupleKeyShares cannot be null");
        }

        List<UpdateTokenItem> items = updateToken.items();
        if (items.size() != updateTupleKeyShares.length) {
            throw new IllegalArgumentException("Mismatch between update token items and update tuple key shares");
        }

        Set<IndexAddress> batchAddresses = new HashSet<IndexAddress>(items.size());
        for (int i = 0; i < items.size(); i++) {
            UpdateTokenItem item = items.get(i);
            VerifiableShare updateTupleKeyShare = updateTupleKeyShares[i];

            if (item == null || updateTupleKeyShare == null) {
                throw new IllegalArgumentException("Update token items and tuple key shares cannot contain null values");
            }

            IndexAddress address = item.address();
            if (!batchAddresses.add(address)) {
                throw new IllegalArgumentException("Duplicate address inside the same update token");
            }
            if (state.invertedIndexStore().contains(address)) {
                throw new IllegalArgumentException("Address already exists in the inverted index");
            }
        }

        for (int i = 0; i < items.size(); i++) {
            UpdateTokenItem item = items.get(i);
            IndexAddress address = item.address();

            state.invertedIndexStore().put(address, item.indexEntry());
            state.keyShareStore().putUpdateTupleShare(address, updateTupleKeyShares[i]);
        }
    }
}
