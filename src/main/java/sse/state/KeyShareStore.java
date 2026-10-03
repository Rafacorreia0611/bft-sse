package sse.state;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import sse.domain.id.IndexAddress;
import vss.secretsharing.VerifiableShare;

public final class KeyShareStore {

    private Map<IndexAddress, VerifiableShare> updateTupleShares;
    private VerifiableShare masterKeyShare;

    public KeyShareStore() {
        this.updateTupleShares = new LinkedHashMap<>();
        this.masterKeyShare = null;
    }

    public VerifiableShare getUpdateTupleShare(IndexAddress address) {
        return updateTupleShares.get(address);
    }

    public void putUpdateTupleShare(IndexAddress address, VerifiableShare share) {
        updateTupleShares.put(address, share);
    }

    public VerifiableShare masterKeyShare() {
        return masterKeyShare;
    }

    public boolean hasMasterKeyShare() {
        return masterKeyShare != null;
    }

    public void setMasterKeyShare(VerifiableShare share) {
        masterKeyShare = share;
    }

    public List<IndexAddress> snapshotUpdateTupleShareOrder() {
        return new ArrayList<>(updateTupleShares.keySet());
    }

    public VerifiableShare[] sharesInOrder(List<IndexAddress> updateTupleShareOrder,
                                           boolean includeMasterKeyShare) {
        int size = updateTupleShareOrder.size()
                + (includeMasterKeyShare ? 1 : 0);
        if (size == 0) {
            return new VerifiableShare[0];
        }

        VerifiableShare[] shares = new VerifiableShare[size];
        int index = 0;
        if (includeMasterKeyShare) {
            shares[index++] = masterKeyShare;
        }
        for (IndexAddress address : updateTupleShareOrder) {
            shares[index++] = updateTupleShares.get(address);
        }
        return shares;
    }

    public void restoreUpdateTupleShares(Map<IndexAddress, VerifiableShare> shares) {
        this.updateTupleShares = new LinkedHashMap<>(shares);
    }
}
