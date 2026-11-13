# Run manually from the repository root:
#   gnuplot benchmarkSSE/gnuplot/update/latency_by_docs/update_latency_by_docs_final.gp
# Override paths with: gnuplot -e "input_path='...'; output_path='...'" SCRIPT.gp

if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/latency_final_2026_11_12/update_by_docs_final.tsv"
}
if (!exists("output_path")) {
    output_path = "benchmarkSSE/plots/final_latency/update_latency_by_docs.pdf"
}

set terminal pdfcairo enhanced color size 7.4in,5.0in font "Helvetica,12"
set output output_path

set border lw 1.1 lc rgb "#30343b"
set tics in scale 0.9,0.45 font "Helvetica,13" textcolor rgb "#30343b"
set grid xtics ytics back lc rgb "#65717f" lw 1.1 dt 3
set xlabel "#Servers" font "Helvetica,14" offset 0,0.3
set ylabel "Latency (s)" font "Helvetica,14" offset -0.4,0
set xrange [3.94:10.06]
set xtics ("4" 4, "7" 7, "10" 10) mirror
set logscale y 10
set yrange [5:200]
set ytics ("5" 5, "10" 10, "20" 20, "30" 30, "50" 50, \
           "75" 75, "100" 100, "150" 150, "200" 200) mirror
set mytics 2
unset x2tics
unset y2tics
set format y "%g"
set lmargin 11.4
set rmargin 2.5
set tmargin 1.7
set bmargin 4.2

set key at graph 0.018,0.982 left top opaque box \
    samplen 2.0 spacing 1.2 width -0.8 font "Helvetica,12"
set label 1 "Y-axis in logarithmic scale" at graph 0.98,0.97 right front \
    font "Helvetica,9" textcolor rgb "#737982"

set style line 1 lc rgb "#0072B2" lw 2.1 pt 7 ps 1.05
set style line 2 lc rgb "#009E73" lw 2.1 pt 5 ps 1.15
set style line 3 lc rgb "#D55E00" lw 2.1 pt 9 ps 1.15
set style line 4 lc rgb "#CC79A7" lw 2.1 pt 11 ps 1.15
set bars 4

docs = "1000 5000 10000 15000"
labels = "1k 5k 10k 15k"

# Source columns: SSE replicas=1, update size=3, metric=7,
# mean_ms=9, sd_ms=10. Convert milliseconds to seconds on the plot.
# Vertical bars show mean +/- one sample standard deviation.
plot for [i=1:4] sprintf("< awk -F '\\t' '$7==\"total_latency\" && $3==%s {print $1, $9, $10}' '%s'", word(docs,i), input_path) \
        using 1:($2/1000):(($2-$3)/1000):(($2+$3)/1000) with yerrorbars ls i lw 1.25 pt 0 notitle, \
     for [i=1:4] sprintf("< awk -F '\\t' '$7==\"total_latency\" && $3==%s {print $1, $9, $10}' '%s'", word(docs,i), input_path) \
        using 1:($2/1000) with linespoints ls i title sprintf("%s Update Size", word(labels,i))

unset output
