package sse.benchmark.coordination;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.concurrent.TimeUnit;

import sse.benchmark.configs.ConcurrentWorkloadConfig;

public final class BenchmarkSynchronizer implements AutoCloseable {

    public static final int PHASE_WARMUP = 1;
    public static final int PHASE_MEASUREMENT = 2;
    public static final int PHASE_FINISHED = 3;

    static final int MESSAGE_REGISTER = 1;
    static final int MESSAGE_ARRIVE = 2;
    static final int MESSAGE_RELEASE = 3;
    static final int MESSAGE_FAILED = 4;
    static final int MESSAGE_ABORT = 5;

    private static final long CONNECT_RETRY_MILLIS = 1000L;

    private final int workerId;
    private final Socket socket;
    private final DataInputStream input;
    private final DataOutputStream output;
    private final BenchmarkCoordinator coordinator;
    private int lastPhase;

    private BenchmarkSynchronizer(int workerId,
                                  Socket socket,
                                  BenchmarkCoordinator coordinator) throws IOException {
        this.workerId = workerId;
        this.socket = socket;
        this.coordinator = coordinator;
        this.input = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
        this.output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
    }

    public static BenchmarkSynchronizer open(ConcurrentWorkloadConfig config,
                                             int timeoutSeconds) throws IOException {
        BenchmarkCoordinator coordinator = null;
        if (config.workerId() == 0) {
            coordinator = new BenchmarkCoordinator(
                    config.coordinatorPort(),
                    config.workerCount(),
                    timeoutSeconds
            );
            coordinator.start();
        }

        String host = config.workerId() == 0 ? "127.0.0.1" : config.coordinatorHost();
        try {
            Socket socket = connectWithRetry(host, config.coordinatorPort(), timeoutSeconds);
            BenchmarkSynchronizer synchronizer = new BenchmarkSynchronizer(
                    config.workerId(),
                    socket,
                    coordinator
            );
            synchronizer.register(config);
            return synchronizer;
        } catch (IOException failure) {
            if (coordinator != null) {
                coordinator.close();
            }
            throw failure;
        }
    }

    public long awaitPhase(int phase) throws IOException {
        validateNextPhase(phase);

        output.writeInt(MESSAGE_ARRIVE);
        output.writeInt(workerId);
        output.writeInt(phase);
        output.flush();

        int messageType = input.readInt();
        if (messageType == MESSAGE_ABORT) {
            throw new IllegalStateException("Benchmark coordinator aborted the run: " + input.readUTF());
        }
        if (messageType != MESSAGE_RELEASE) {
            throw new IllegalStateException("Unexpected coordinator message: " + messageType);
        }

        int releasedPhase = input.readInt();
        if (releasedPhase != phase) {
            throw new IllegalStateException(
                    "Expected release for phase " + phase + " but received " + releasedPhase
            );
        }

        lastPhase = phase;
        return System.nanoTime();
    }

    public void reportFailure(int phase, Throwable failure) {
        try {
            output.writeInt(MESSAGE_FAILED);
            output.writeInt(workerId);
            output.writeInt(phase);
            output.writeUTF(shortFailureMessage(failure));
            output.flush();
        } catch (IOException ignored) {
            // Preserve the original benchmark failure.
        }
    }

    private void register(ConcurrentWorkloadConfig config) throws IOException {
        output.writeInt(MESSAGE_REGISTER);
        output.writeInt(config.workerId());
        output.writeInt(config.workerCount());
        output.writeInt(config.clientIndexStart());
        output.writeInt(config.localClientCount());
        output.writeInt(config.clientCount());
        output.writeInt(config.clientId());
        output.writeUTF(config.scenarioName());
        output.writeLong(config.seed());
        output.writeInt(config.warmupSeconds());
        output.writeInt(config.measurementSeconds());
        output.writeInt(config.warmupKeywordCount());
        output.writeInt(config.searchPercentage());
        output.writeUTF(config.keywordSelectionDistribution().name());
        output.writeDouble(config.zipfianExponent());
        output.writeUTF(config.lockContentionLevel().name());
        output.writeInt(config.sharedKeywordCount());
        output.flush();
    }

    private void validateNextPhase(int phase) {
        int expectedPhase;
        if (lastPhase == 0) {
            expectedPhase = PHASE_WARMUP;
        } else if (lastPhase == PHASE_WARMUP) {
            expectedPhase = PHASE_MEASUREMENT;
        } else if (lastPhase == PHASE_MEASUREMENT) {
            expectedPhase = PHASE_FINISHED;
        } else {
            throw new IllegalStateException("All benchmark phases have already completed");
        }

        if (phase != expectedPhase) {
            throw new IllegalStateException(
                    "Expected benchmark phase " + expectedPhase + " but received " + phase
            );
        }
    }

    private static Socket connectWithRetry(String host,
                                           int port,
                                           int timeoutSeconds) throws IOException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds);
        IOException lastFailure = null;

        while (System.nanoTime() < deadline) {
            Socket socket = new Socket();
            try {
                socket.connect(new InetSocketAddress(host, port), 5000);
                socket.setSoTimeout((int) TimeUnit.SECONDS.toMillis(timeoutSeconds));
                return socket;
            } catch (IOException failure) {
                lastFailure = failure;
                try {
                    socket.close();
                } catch (IOException ignored) {
                }

                try {
                    Thread.sleep(CONNECT_RETRY_MILLIS);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IOException("Interrupted while connecting to the benchmark coordinator", interrupted);
                }
            }
        }

        throw new IOException(
                "Timed out connecting to benchmark coordinator " + host + ':' + port,
                lastFailure
        );
    }

    private String shortFailureMessage(Throwable failure) {
        String message = failure.getMessage();
        if (message == null || message.trim().isEmpty()) {
            message = failure.getClass().getSimpleName();
        }
        return message.length() <= 500 ? message : message.substring(0, 500);
    }

    @Override
    public void close() {
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        if (coordinator != null) {
            coordinator.close();
        }
    }
}
