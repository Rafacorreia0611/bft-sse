package sse.demo.server;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.ObjectOutput;
import java.io.ObjectOutputStream;

import confidential.ConfidentialMessage;
import confidential.statemanagement.ConfidentialSnapshot;
import sse.demo.messages.ResponseStatus;
import sse.domain.setup.InitialStatePayload;
import sse.domain.search.SearchResponseData;
import sse.domain.search.SearchToken;
import sse.domain.state.State;
import sse.domain.update.UpdateToken;
import sse.facade.SSEServerFacade;
import sse.snapshot.SSEPlainSnapshotData;
import vss.secretsharing.VerifiableShare;

public final class SSEServerHandler {

    private final SSEServerFacade sseServerFacade;

    public SSEServerHandler() {
        this.sseServerFacade = new SSEServerFacade();
    }

    public boolean initializeState(InitialStatePayload initialStatePayload,
                                   VerifiableShare masterKeyShare) {
        if (initialStatePayload == null) {
            return false;
        }
        return sseServerFacade.initializeState(
                initialStatePayload.encryptedKeywordLocationMap(),
                masterKeyShare
        );
    }

    public ConfidentialMessage handleIsInitialized() {
        return new ConfidentialMessage(new byte[] {
                (byte) ResponseStatus.OK.ordinal(),
                (byte) (sseServerFacade.isInitialized() ? 1 : 0)
        });
    }

    public ConfidentialMessage handleSearch(SearchToken searchToken) {
        if (!sseServerFacade.isInitialized() || searchToken == null) {
            return statusMessage(ResponseStatus.FAILED);
        }
        SearchResponseData searchResults = sseServerFacade.searchQuery(searchToken);
        byte[] plainResponse = serializeResponse(ResponseStatus.OK, searchResults.encryptedTuples());
        return new ConfidentialMessage(plainResponse, searchResults.updateTupleSharesArray());
    }

    public ConfidentialMessage handleState() {
        if (!sseServerFacade.isInitialized()) {
            return statusMessage(ResponseStatus.FAILED);
        }

        State state = sseServerFacade.getState();
        VerifiableShare masterKeyShare = sseServerFacade.getMasterKey();

        byte[] plainResponse = serializeResponse(ResponseStatus.OK, state);
        if (masterKeyShare == null) {
            return new ConfidentialMessage(plainResponse);
        }

        return new ConfidentialMessage(plainResponse, masterKeyShare);
    }

    public ConfidentialMessage handleUpdate(int clientId, UpdateToken updateToken, VerifiableShare[] updateTupleKeyShares) {
        try {
            if (!sseServerFacade.isInitialized() || updateToken == null || updateTupleKeyShares == null) {
                return statusMessage(ResponseStatus.FAILED);
            }
            sseServerFacade.updateQuery(updateToken, updateTupleKeyShares);
            return statusMessage(ResponseStatus.OK);
        } catch (IllegalArgumentException e) {
            System.err.println("Rejected update from client " + clientId + ": " + e.getMessage());
            return statusMessage(ResponseStatus.FAILED);
        }
    }

    public ConfidentialSnapshot getConfidentialSnapshot() {
        SSEPlainSnapshotData sseSnapshotData = sseServerFacade.getPlainSnapshotData();
        byte[] plainData = sseSnapshotData.serialize();
        VerifiableShare[] shares = sseServerFacade.getSnapshotShares(
                sseSnapshotData.updateTupleShareOrder(),
                sseSnapshotData.hasMasterKeyShare()
        );
        return new ConfidentialSnapshot(plainData, shares);
    }

    public void installConfidentialSnapshot(ConfidentialSnapshot cs) {
        SSEPlainSnapshotData snapshot = SSEPlainSnapshotData.deserialize(cs.getPlainData());
        sseServerFacade.installSnapshot(
                snapshot,
                snapshot.masterKeyShare(cs.getShares()),
                snapshot.updateTupleShares(cs.getShares())
        );
    }

    private ConfidentialMessage statusMessage(ResponseStatus status) {
        return new ConfidentialMessage(new byte[]{(byte) status.ordinal()});
    }

    private byte[] serializeResponse(ResponseStatus status, Object payload) {
        try (ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            bos.write((byte) status.ordinal());
            try (ObjectOutput out = new ObjectOutputStream(bos)) {
                out.writeObject(payload);
                out.flush();
            }
            bos.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Error serializing response", e);
        }
    }
}
