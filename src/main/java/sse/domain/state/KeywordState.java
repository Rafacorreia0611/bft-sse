package sse.domain.state;

import java.io.Serializable;
import java.util.Objects;

import sse.domain.id.SearchTokenValue;

public final class KeywordState implements Serializable {

    public static final int STATE_LENGTH_BYTES = 16;

    private final SearchTokenValue currentToken;
    private final int counter;

    public KeywordState(SearchTokenValue currentToken, int counter) {
        if (currentToken == null || currentToken.value().length != STATE_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    "currentToken must be exactly " + STATE_LENGTH_BYTES + " bytes");
        }
        if (counter <= 0) {
            throw new IllegalArgumentException("counter must be greater than zero");
        }
        this.currentToken = currentToken;
        this.counter = counter;
    }

    public SearchTokenValue currentToken() {
        return currentToken;
    }

    public int counter() {
        return counter;
    }

    public KeywordState withCurrentToken(SearchTokenValue currentToken) {
        return new KeywordState(currentToken, counter);
    }

    public KeywordState withCounter(int counter) {
        return new KeywordState(currentToken, counter);
    }

    public KeywordState advanceTo(SearchTokenValue currentToken) {
        return new KeywordState(currentToken, counter + 1);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        KeywordState that = (KeywordState) o;
        return counter == that.counter
                && Objects.equals(currentToken, that.currentToken);
    }

    @Override
    public int hashCode() {
        return Objects.hash(currentToken, counter);
    }

    @Override
    public String toString() {
        return "KeywordState[" +
                "currentToken=" + currentToken +
                ", counter=" + counter +
                ']';
    }
}
