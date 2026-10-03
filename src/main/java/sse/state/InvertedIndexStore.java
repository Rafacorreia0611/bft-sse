package sse.state;

import java.util.LinkedHashMap;
import java.util.Map;

import sse.domain.id.IndexAddress;
import sse.domain.update.IndexEntry;

public final class InvertedIndexStore {

    private Map<IndexAddress, IndexEntry> entries;

    public InvertedIndexStore() {
        this.entries = new LinkedHashMap<>();
    }

    public boolean contains(IndexAddress address) {
        return entries.containsKey(address);
    }

    public IndexEntry get(IndexAddress address) {
        return entries.get(address);
    }

    public void put(IndexAddress address, IndexEntry entry) {
        entries.put(address, entry);
    }

    public Map<IndexAddress, IndexEntry> snapshot() {
        return new LinkedHashMap<>(entries);
    }

    public void restore(Map<IndexAddress, IndexEntry> snapshot) {
        this.entries = new LinkedHashMap<>(snapshot);
    }
}
