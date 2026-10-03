package sse.snapshot;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.ObjectInput;
import java.io.ObjectInputStream;
import java.io.ObjectOutput;
import java.io.ObjectOutputStream;
import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import sse.domain.id.IndexAddress;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.update.IndexEntry;
import vss.secretsharing.VerifiableShare;

public final class SSEPlainSnapshotData implements Serializable {
    private final EncryptedKeywordLocationMap encryptedKeywordLocationMap;
    private final Map<IndexAddress, IndexEntry> invertedIndex;
    private final List<IndexAddress> updateTupleShareOrder;
    private final boolean hasMasterKeyShare;

    public SSEPlainSnapshotData(EncryptedKeywordLocationMap encryptedKeywordLocationMap,
                                Map<IndexAddress, IndexEntry> invertedIndex,
                                List<IndexAddress> updateTupleShareOrder,
                                boolean hasMasterKeyShare) {
        this.encryptedKeywordLocationMap = encryptedKeywordLocationMap;
        this.invertedIndex = new LinkedHashMap<>(invertedIndex);
        this.updateTupleShareOrder = new ArrayList<>(updateTupleShareOrder);
        this.hasMasterKeyShare = hasMasterKeyShare;
    }

    public EncryptedKeywordLocationMap encryptedKeywordLocationMap() {
        return encryptedKeywordLocationMap;
    }

    public Map<IndexAddress, IndexEntry> invertedIndex() {
        return new LinkedHashMap<>(invertedIndex);
    }

    public List<IndexAddress> updateTupleShareOrder() {
        return new ArrayList<>(updateTupleShareOrder);
    }

    public boolean hasMasterKeyShare() {
        return hasMasterKeyShare;
    }

    public byte[] serialize() {
        try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
             ObjectOutput out = new ObjectOutputStream(bos)) {
            out.writeObject(this);
            out.flush();
            bos.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Error serializing snapshot", e);
        }
    }

    public static SSEPlainSnapshotData deserialize(byte[] plainData) {
        try (ByteArrayInputStream bis = new ByteArrayInputStream(plainData);
             ObjectInput in = new ObjectInputStream(bis)) {
            Object snapshot = in.readObject();
            if (!(snapshot instanceof SSEPlainSnapshotData)) {
                throw new IllegalArgumentException("Snapshot data has invalid type");
            }
            return (SSEPlainSnapshotData) snapshot;
        } catch (IOException | ClassNotFoundException e) {
            throw new RuntimeException("Error deserializing snapshot", e);
        }
    }

    public VerifiableShare masterKeyShare(VerifiableShare[] shares) {
        if (!hasMasterKeyShare) {
            return null;
        }
        if (shares == null || shares.length == 0) {
            throw new IllegalStateException("Snapshot is missing master key share");
        }
        return shares[0];
    }

    public Map<IndexAddress, VerifiableShare> updateTupleShares(VerifiableShare[] shares) {
        int index = 0;
        if (hasMasterKeyShare) {
            index++;
        }
        Map<IndexAddress, VerifiableShare> result = new LinkedHashMap<IndexAddress, VerifiableShare>();
        for (IndexAddress address : updateTupleShareOrder) {
            if (shares == null || index >= shares.length) {
                throw new IllegalStateException("Snapshot is missing update tuple shares");
            }
            result.put(address, shares[index++]);
        }
        if (shares != null && index != shares.length) {
            throw new IllegalStateException("Snapshot contains unexpected extra shares");
        }
        return result;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        SSEPlainSnapshotData that = (SSEPlainSnapshotData) o;
        return hasMasterKeyShare == that.hasMasterKeyShare &&
                Objects.equals(encryptedKeywordLocationMap, that.encryptedKeywordLocationMap) &&
                Objects.equals(invertedIndex, that.invertedIndex) &&
                Objects.equals(updateTupleShareOrder, that.updateTupleShareOrder);
    }

    @Override
    public int hashCode() {
        return Objects.hash(encryptedKeywordLocationMap, invertedIndex, updateTupleShareOrder,
                hasMasterKeyShare);
    }

    @Override
    public String toString() {
        return "SSEPlainSnapshotData[" +
                "encryptedKeywordLocationMap=" + encryptedKeywordLocationMap +
                ", invertedIndex=" + invertedIndex +
                ", updateTupleShareOrder=" + updateTupleShareOrder +
                ", hasMasterKeyShare=" + hasMasterKeyShare +
                ']';
    }
}
