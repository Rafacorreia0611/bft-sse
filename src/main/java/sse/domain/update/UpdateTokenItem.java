package sse.domain.update;

import java.io.Serializable;
import java.util.Objects;

import sse.domain.id.IndexAddress;

public final class UpdateTokenItem implements Serializable {

    private final IndexAddress address;
    private final IndexEntry indexEntry;

    public UpdateTokenItem(IndexAddress address, IndexEntry indexEntry) {
        if (address == null || indexEntry == null) {
            throw new IllegalArgumentException("address and indexEntry cannot be null");
        }
        this.address = address;
        this.indexEntry = indexEntry;
    }

    public IndexAddress address() {
        return address;
    }

    public IndexEntry indexEntry() {
        return indexEntry;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        UpdateTokenItem that = (UpdateTokenItem) o;
        return Objects.equals(address, that.address)
                && Objects.equals(indexEntry, that.indexEntry);
    }

    @Override
    public int hashCode() {
        return Objects.hash(address, indexEntry);
    }

    @Override
    public String toString() {
        return "UpdateTokenItem[" +
                "address=" + address +
                ", indexEntry=" + indexEntry +
                ']';
    }
}
