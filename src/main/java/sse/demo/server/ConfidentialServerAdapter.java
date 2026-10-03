package sse.demo.server;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.ObjectInput;
import java.io.ObjectInputStream;

import bftsmart.tom.MessageContext;
import confidential.ConfidentialMessage;
import confidential.facade.server.ConfidentialServerFacade;
import confidential.facade.server.ConfidentialSingleExecutable;
import confidential.statemanagement.ConfidentialSnapshot;
import sse.demo.messages.RequestType;
import sse.demo.messages.ResponseStatus;
import sse.domain.setup.InitialStatePayload;
import sse.domain.search.SearchToken;
import sse.domain.update.UpdateToken;
import vss.secretsharing.VerifiableShare;

public final class ConfidentialServerAdapter implements ConfidentialSingleExecutable {

    private final SSEServerHandler handler;

    ConfidentialServerAdapter(int processId) {
        this.handler = new SSEServerHandler();
        new ConfidentialServerFacade(processId, this);
    }

    @Override
    public ConfidentialMessage appExecuteOrdered(byte[] plainData, VerifiableShare[] vss, MessageContext mc) {
        try (ByteArrayInputStream bis = new ByteArrayInputStream(plainData);
             ObjectInput in = new ObjectInputStream(bis)) {
            RequestType type = RequestType.getRequestType(in.read());
            int clientId = in.readInt();
            switch (type) {
                case INIT_STATE:
                    InitialStatePayload initialStatePayload = InitialStatePayload.deserialize(readPayload(in));
                    return statusMessage(
                            handler.initializeState(
                                    initialStatePayload,
                                    vss != null && vss.length == 1 ? vss[0] : null
                            ) ? ResponseStatus.OK : ResponseStatus.FAILED
                    );
                case IS_INITIALIZED:
                    return handler.handleIsInitialized();
                case SEARCH:
                    SearchToken searchToken = SearchToken.deserialize(readPayload(in));
                    return handler.handleSearch(searchToken);
                case UPDATE:
                    UpdateToken updateToken = UpdateToken.deserialize(readPayload(in));
                    return handler.handleUpdate(clientId, updateToken, vss);
                case STATE:
                    return handler.handleState();
                default:
                    throw new IllegalArgumentException("Unknown request type: " + type);
            }
        } catch (IOException e) {
            throw new RuntimeException("Error processing request", e);
        }
    }

    @Override
    public ConfidentialMessage appExecuteUnordered(byte[] bytes, VerifiableShare[] vss, MessageContext mc) {
        throw new UnsupportedOperationException("Not supported yet.");
    }

    @Override
    public ConfidentialSnapshot getConfidentialSnapshot() {
        return handler.getConfidentialSnapshot();
    }

    @Override
    public void installConfidentialSnapshot(ConfidentialSnapshot cs) {
        handler.installConfidentialSnapshot(cs);
    }

    private ConfidentialMessage statusMessage(ResponseStatus status) {
        return new ConfidentialMessage(new byte[]{(byte) status.ordinal()});
    }

    private byte[] readPayload(ObjectInput in) {
        try {
            int length = in.readInt();
            if (length < 0) {
                return null;
            }
            byte[] payload = new byte[length];
            in.readFully(payload);
            return payload;
        } catch (IOException e) {
            throw new RuntimeException("Error reading request payload", e);
        }
    }
}
