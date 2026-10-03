package sse.service.server;

import java.util.List;
import java.util.Map;

import sse.domain.id.IndexAddress;
import sse.snapshot.SSEPlainSnapshotData;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public final class SnapshotService {

    public SSEPlainSnapshotData getPlainSnapshotData(SSEServerState state) {
        return new SSEPlainSnapshotData(
                state.encryptedKeywordLocationMap(),
                state.invertedIndexStore().snapshot(),
                state.keyShareStore().snapshotUpdateTupleShareOrder(),
                state.keyShareStore().hasMasterKeyShare()
        );
    }

    public VerifiableShare[] getSnapshotShares(SSEServerState state, List<IndexAddress> updateTupleShareOrder,
                                               boolean includeMasterKeyShare) {
        return state.keyShareStore().sharesInOrder(
                updateTupleShareOrder,
                includeMasterKeyShare
        );
    }

    public void installSnapshot(SSEServerState state, SSEPlainSnapshotData snapshotData, VerifiableShare masterKeyShare,
                                Map<IndexAddress, VerifiableShare> updateTupleShares) {
        if (snapshotData == null) {
            throw new IllegalArgumentException("snapshotData cannot be null");
        }
        state.setEncryptedKeywordLocationMap(snapshotData.encryptedKeywordLocationMap());
        state.invertedIndexStore().restore(snapshotData.invertedIndex());
        state.keyShareStore().restoreUpdateTupleShares(updateTupleShares);
        state.keyShareStore().setMasterKeyShare(masterKeyShare);
    }
}
