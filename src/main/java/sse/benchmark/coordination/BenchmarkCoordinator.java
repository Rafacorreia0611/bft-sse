package sse.benchmark.coordination;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.TimeUnit;

final class BenchmarkCoordinator implements AutoCloseable {

    private final ServerSocket serverSocket;
    private final int workerCount;
    private final int timeoutMillis;
    private final Socket[] sockets;
    private final DataInputStream[] inputs;
    private final DataOutputStream[] outputs;
    private final int[] clientStarts;
    private final int[] localClientCounts;

    private Thread thread;
    private volatile boolean closed;

    BenchmarkCoordinator(int port, int workerCount, int timeoutSeconds) throws IOException {
        this.workerCount = workerCount;
        this.timeoutMillis = (int) TimeUnit.SECONDS.toMillis(timeoutSeconds);
        this.sockets = new Socket[workerCount];
        this.inputs = new DataInputStream[workerCount];
        this.outputs = new DataOutputStream[workerCount];
        this.clientStarts = new int[workerCount];
        this.localClientCounts = new int[workerCount];

        this.serverSocket = new ServerSocket();
        serverSocket.setReuseAddress(true);
        serverSocket.bind(new InetSocketAddress(port));
        serverSocket.setSoTimeout(timeoutMillis);
    }

    void start() {
        thread = new Thread(this::run, "benchmark-coordinator");
        thread.start();
    }

    private void run() {
        try {
            acceptAndRegisterWorkers();
            synchronizePhase(BenchmarkSynchronizer.PHASE_WARMUP);
            synchronizePhase(BenchmarkSynchronizer.PHASE_MEASUREMENT);
            synchronizePhase(BenchmarkSynchronizer.PHASE_FINISHED);
            System.out.println("All distributed benchmark workers finished.");
        } catch (Throwable failure) {
            if (!closed) {
                System.err.println("Benchmark coordinator failed: " + failure.getMessage());
                broadcastAbort(failure.getMessage());
            }
        } finally {
            closeConnections();
        }
    }

    private void acceptAndRegisterWorkers() throws IOException {
        String expectedScenario = null;
        long expectedSeed = 0L;
        int expectedTotalClients = -1;
        int expectedBaseClientId = -1;
        int expectedWarmupSeconds = -1;
        int expectedMeasurementSeconds = -1;
        int expectedWarmupKeywordCount = -1;
        int expectedSearchPercentage = -1;
        String expectedKeywordDistribution = null;
        double expectedZipfianExponent = 0.0;
        String expectedContentionLevel = null;
        int expectedSharedKeywordCount = -1;

        for (int connectionIndex = 0; connectionIndex < workerCount; connectionIndex++) {
            Socket socket = serverSocket.accept();
            socket.setSoTimeout(timeoutMillis);
            DataInputStream input = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
            DataOutputStream output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));

            int messageType = input.readInt();
            if (messageType != BenchmarkSynchronizer.MESSAGE_REGISTER) {
                sendAbort(output, "First worker message must be REGISTER");
                throw new IllegalArgumentException("First worker message must be REGISTER");
            }

            int workerId = input.readInt();
            int configuredWorkerCount = input.readInt();
            int clientStart = input.readInt();
            int localClientCount = input.readInt();
            int totalClientCount = input.readInt();
            int baseClientId = input.readInt();
            String scenario = input.readUTF();
            long seed = input.readLong();
            int warmupSeconds = input.readInt();
            int measurementSeconds = input.readInt();
            int warmupKeywordCount = input.readInt();
            int searchPercentage = input.readInt();
            String keywordDistribution = input.readUTF();
            double zipfianExponent = input.readDouble();
            String contentionLevel = input.readUTF();
            int sharedKeywordCount = input.readInt();

            if (configuredWorkerCount != workerCount) {
                sendAbort(output, "Workers disagree on workerCount");
                throw new IllegalArgumentException("Worker " + workerId
                        + " reports workerCount=" + configuredWorkerCount + ", expected " + workerCount);
            }
            if (workerId < 0 || workerId >= workerCount) {
                sendAbort(output, "Invalid worker ID: " + workerId);
                throw new IllegalArgumentException("Invalid worker ID: " + workerId);
            }
            if (sockets[workerId] != null) {
                sendAbort(output, "Duplicate worker ID: " + workerId);
                throw new IllegalArgumentException("Duplicate worker ID: " + workerId);
            }

            sockets[workerId] = socket;
            inputs[workerId] = input;
            outputs[workerId] = output;

            if (connectionIndex == 0) {
                expectedScenario = scenario;
                expectedSeed = seed;
                expectedTotalClients = totalClientCount;
                expectedBaseClientId = baseClientId;
                expectedWarmupSeconds = warmupSeconds;
                expectedMeasurementSeconds = measurementSeconds;
                expectedWarmupKeywordCount = warmupKeywordCount;
                expectedSearchPercentage = searchPercentage;
                expectedKeywordDistribution = keywordDistribution;
                expectedZipfianExponent = zipfianExponent;
                expectedContentionLevel = contentionLevel;
                expectedSharedKeywordCount = sharedKeywordCount;
            } else {
                requireEqual("scenario", expectedScenario, scenario);
                requireEqual("workload seed", expectedSeed, seed);
                requireEqual("total client count", expectedTotalClients, totalClientCount);
                requireEqual("base client ID", expectedBaseClientId, baseClientId);
                requireEqual("warm-up duration", expectedWarmupSeconds, warmupSeconds);
                requireEqual("measurement duration", expectedMeasurementSeconds, measurementSeconds);
                requireEqual("warm-up keyword count", expectedWarmupKeywordCount, warmupKeywordCount);
                requireEqual("search percentage", expectedSearchPercentage, searchPercentage);
                requireEqual("keyword distribution", expectedKeywordDistribution, keywordDistribution);
                requireEqual("Zipfian exponent", expectedZipfianExponent, zipfianExponent);
                requireEqual("contention level", expectedContentionLevel, contentionLevel);
                requireEqual("shared keyword count", expectedSharedKeywordCount, sharedKeywordCount);
            }

            clientStarts[workerId] = clientStart;
            localClientCounts[workerId] = localClientCount;

            System.out.println("Registered benchmark worker " + workerId
                    + " with logical clients [" + clientStart + ','
                    + (clientStart + localClientCount) + ")");
        }

        validateClientPartition(expectedTotalClients);
    }

    private void validateClientPartition(int totalClientCount) {
        if (totalClientCount <= 0) {
            throw new IllegalArgumentException("Total client count must be positive");
        }

        boolean[] assigned = new boolean[totalClientCount];
        for (int workerId = 0; workerId < workerCount; workerId++) {
            int start = clientStarts[workerId];
            int count = localClientCounts[workerId];
            long end = (long) start + count;

            if (start < 0 || count <= 0 || end > totalClientCount) {
                throw new IllegalArgumentException("Invalid client range for worker " + workerId);
            }

            for (int clientIndex = start; clientIndex < end; clientIndex++) {
                if (assigned[clientIndex]) {
                    throw new IllegalArgumentException(
                            "Logical client index " + clientIndex + " is assigned more than once"
                    );
                }
                assigned[clientIndex] = true;
            }
        }

        for (int clientIndex = 0; clientIndex < assigned.length; clientIndex++) {
            if (!assigned[clientIndex]) {
                throw new IllegalArgumentException(
                        "Logical client index " + clientIndex + " is not assigned to any worker"
                );
            }
        }
    }

    private void synchronizePhase(int expectedPhase) throws IOException {
        for (int workerId = 0; workerId < workerCount; workerId++) {
            int messageType = inputs[workerId].readInt();
            if (messageType == BenchmarkSynchronizer.MESSAGE_FAILED) {
                throw readWorkerFailure(workerId);
            }
            if (messageType != BenchmarkSynchronizer.MESSAGE_ARRIVE) {
                throw new IllegalStateException("Expected ARRIVE from worker " + workerId);
            }

            int reportedWorkerId = inputs[workerId].readInt();
            int reportedPhase = inputs[workerId].readInt();
            if (reportedWorkerId != workerId) {
                throw new IllegalStateException("Worker identity mismatch");
            }
            if (reportedPhase != expectedPhase) {
                throw new IllegalStateException("Worker " + workerId + " reached phase "
                        + reportedPhase + ", expected " + expectedPhase);
            }
        }

        long releaseStart = System.nanoTime();
        for (int workerId = 0; workerId < workerCount; workerId++) {
            outputs[workerId].writeInt(BenchmarkSynchronizer.MESSAGE_RELEASE);
            outputs[workerId].writeInt(expectedPhase);
            outputs[workerId].flush();
        }
        long releaseSpan = System.nanoTime() - releaseStart;
        System.out.println("Released benchmark phase " + expectedPhase + " to " + workerCount
                + " workers in " + releaseSpan + " ns.");
    }

    private IllegalStateException readWorkerFailure(int expectedWorkerId) throws IOException {
        int reportedWorkerId = inputs[expectedWorkerId].readInt();
        int phase = inputs[expectedWorkerId].readInt();
        String message = inputs[expectedWorkerId].readUTF();
        return new IllegalStateException("Worker " + reportedWorkerId
                + " failed during phase " + phase + ": " + message);
    }

    private void broadcastAbort(String reason) {
        String safeReason = reason == null ? "Unknown coordinator failure" : reason;
        for (DataOutputStream output : outputs) {
            if (output != null) {
                sendAbort(output, safeReason);
            }
        }
    }

    private void sendAbort(DataOutputStream output, String reason) {
        try {
            output.writeInt(BenchmarkSynchronizer.MESSAGE_ABORT);
            output.writeUTF(reason);
            output.flush();
        } catch (IOException ignored) {
        }
    }

    private void requireEqual(String label, int expected, int actual) {
        if (expected != actual) {
            throw new IllegalArgumentException("Workers disagree on " + label
                    + ": expected " + expected + ", received " + actual);
        }
    }

    private void requireEqual(String label, long expected, long actual) {
        if (expected != actual) {
            throw new IllegalArgumentException("Workers disagree on " + label
                    + ": expected " + expected + ", received " + actual);
        }
    }

    private void requireEqual(String label, double expected, double actual) {
        if (Double.compare(expected, actual) != 0) {
            throw new IllegalArgumentException("Workers disagree on " + label
                    + ": expected " + expected + ", received " + actual);
        }
    }

    private void requireEqual(String label, String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new IllegalArgumentException("Workers disagree on " + label
                    + ": expected " + expected + ", received " + actual);
        }
    }

    private void closeConnections() {
        for (Socket socket : sockets) {
            if (socket != null) {
                try {
                    socket.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    @Override
    public void close() {
        closed = true;
        try {
            serverSocket.close();
        } catch (IOException ignored) {
        }
        closeConnections();

        if (thread != null && thread != Thread.currentThread()) {
            try {
                thread.join(5000L);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
