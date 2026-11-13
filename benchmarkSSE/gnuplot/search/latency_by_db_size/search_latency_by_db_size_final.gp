# Run manually from the repository root:
#   gnuplot benchmarkSSE/gnuplot/search/latency_by_db_size/search_latency_by_db_size_final.gp
# Override either path with: gnuplot -e "input_path='...'; output_path='...'" SCRIPT.gp

if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/latency_final_2026_11_12/search_by_db_size_final.tsv"
}
if (!exists("output_path")) {
    output_path = "benchmarkSSE/plots/final_latency/search_latency_by_db_size.pdf"
}

set terminal pdfcairo enhanced color size 7.4in,5.0in font "Helvetica,12"
set output output_path

set border lw 1.1 lc rgb "#30343b"
set tics in scale 0.9,0.45 font "Helvetica,13" textcolor rgb "#30343b"
set grid xtics ytics back lc rgb "#65717f" lw 1.1 dt 3
set xlabel "Database Size" font "Helvetica,14" offset 0,-0.2
set ylabel "Latency (ms)" font "Helvetica,14" offset -0.4,0
set xrange [95000:1005000]
set xtics ("100k" 100000, "250k" 250000, "500k" 500000, \
           "750k" 750000, "1M" 1000000) mirror
set yrange [0:700]
set ytics 0,100,700 mirror
set mytics 2
unset x2tics
unset y2tics
set lmargin 11.4
set rmargin 2.5
set tmargin 1.7
set bmargin 4.2

set key at graph 0.018,0.982 left top opaque box \
    samplen 2.0 spacing 1.2 width -0.8 font "Helvetica,12"

set style line 1 lc rgb "#0072B2" lw 2.1 pt 7 ps 1.05
set style line 2 lc rgb "#009E73" lw 2.1 pt 5 ps 1.15
set style line 3 lc rgb "#D55E00" lw 2.1 pt 9 ps 1.15
set bars 4

servers = "4 7 10"

# Source columns: SSE replicas=1, database size=3, metric=5,
# mean_ms=7, sd_ms=8. Plot only total-latency rows.
# The vertical bars show mean +/- one sample standard deviation.
plot for [i=1:3] sprintf("< awk -F '\\t' '$5==\"total_latency\" && $1==%s {print $3, $7, $8}' '%s'", word(servers,i), input_path) \
        using 1:2:($2-$3):($2+$3) with yerrorbars ls i lw 1.25 pt 0 notitle, \
     for [i=1:3] sprintf("< awk -F '\\t' '$5==\"total_latency\" && $1==%s {print $3, $7, $8}' '%s'", word(servers,i), input_path) \
        using 1:2 with linespoints ls i title sprintf("%s Servers", word(servers,i))

unset output
