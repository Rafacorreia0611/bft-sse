if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/data/search_latency_by_docs_summary.tsv"
}

if (!exists("mean_output_path")) {
    mean_output_path = "benchmarkSSE/plots/search_latency_mean.png"
}

if (!exists("median_output_path")) {
    median_output_path = "benchmarkSSE/plots/search_latency_median.png"
}

set datafile separator "\t"
set terminal pngcairo size 900,540 enhanced font "Helvetica,12"

set border lw 1.2
set tics out nomirror
set style line 81 lc rgb "#cfcfcf" lt 1 lw 1.1
set grid back xtics ytics ls 81
set key left top opaque box width 1 samplen 2.2 spacing 1.1
set xlabel "Result Size Range"
set ylabel "Time (ms)"
set logscale x 10
set logscale y 10
set xtics rotate by 0 font "Helvetica,11"
set mxtics 10
unset mytics
unset ytics
set ytics nomirror
set style line 1 lc rgb "#d95f02" lt 1 lw 2.5 pt 7 ps 1.4

set output mean_output_path
set title "Mean Search Latency"
plot input_path using (strcol(4) eq "total_latency" ? sqrt($2 * $3) : 1/0):8:xticlabels(1) \
    with linespoints ls 1 title "Total"

set output median_output_path
set title "Median Search Latency"
plot input_path using (strcol(4) eq "total_latency" ? sqrt($2 * $3) : 1/0):7:xticlabels(1) \
    with linespoints ls 1 title "Total"

unset output
