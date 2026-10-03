package sse.facade;

import java.util.Map;
import java.util.List;

import sse.domain.id.IndexAddress;
import sse.domain.search.SearchResponseData;
import sse.domain.search.SearchToken;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.state.State;
import sse.domain.update.UpdateToken;
import sse.snapshot.SSEPlainSnapshotData;
import sse.service.server.SearchService;
import sse.service.server.SnapshotService;
import sse.service.server.UpdateService;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public final class SSEServerFacade {

    private final SSEServerState state;
    private final SearchService searchService;
    private final UpdateService updateService;
    private final SnapshotService snapshotService;

    public SSEServerFacade() {
        this.state = new SSEServerState();
        this.searchService = new SearchService();
        this.updateService = new UpdateService();
        this.snapshotService = new SnapshotService();
    }

    public SearchResponseData searchQuery(SearchToken searchToken) {
        return searchService.search(state, searchToken);
    }

    public void updateQuery(UpdateToken updateToken, VerifiableShare[] updateTupleKeyShares) {
        updateService.update(state, updateToken, updateTupleKeyShares);
    }

    public boolean isInitialized() {
        return state.isInitialized();
    }

    public State getState() {
        if (!state.isInitialized()) {
            throw new IllegalStateException("Server state is not initialized");
        }
        return new State(state.encryptedKeywordLocationMap());
    }

    public VerifiableShare getMasterKey() {
        return state.keyShareStore().masterKeyShare();
    }

    public Boolean initializeState(EncryptedKeywordLocationMap encryptedKeywordLocationMap,
                                   VerifiableShare masterKeyShare) {
        if (encryptedKeywordLocationMap == null || masterKeyShare == null) {
            return false;
        }
        if (state.isInitialized()
                || state.keyShareStore().hasMasterKeyShare()
                || state.encryptedKeywordLocationMap() != null) {
            return false;
        }

        state.setEncryptedKeywordLocationMap(encryptedKeywordLocationMap);
        state.keyShareStore().setMasterKeyShare(masterKeyShare);
        return true;
    }

    public SSEPlainSnapshotData getPlainSnapshotData() {
        return snapshotService.getPlainSnapshotData(state);
    }

    public VerifiableShare[] getSnapshotShares(List<IndexAddress> updateTupleShareOrder,
                                               boolean includeMasterKeyShare) {
        return snapshotService.getSnapshotShares(
                state,
                updateTupleShareOrder,
                includeMasterKeyShare
        );
    }

    public void installSnapshot(SSEPlainSnapshotData snapshotData, VerifiableShare masterKeyShare,
                                Map<IndexAddress, VerifiableShare> updateTupleShares) {
        snapshotService.installSnapshot(
                state,
                snapshotData,
                masterKeyShare,
                updateTupleShares
        );
    }
}
