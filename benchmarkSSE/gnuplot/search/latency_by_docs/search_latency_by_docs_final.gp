# Run manually from the repository root:
#   gnuplot benchmarkSSE/gnuplot/search/latency_by_docs/search_latency_by_docs_final.gp
# Override either path with: gnuplot -e "input_path='...'; output_path='...'" SCRIPT.gp

if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/latency_final_2026_11_12/search_by_docs_final.tsv"
}
if (!exists("output_path")) {
    output_path = "benchmarkSSE/plots/final_latency/search_latency_by_docs.pdf"
}

set terminal pdfcairo enhanced color size 7.4in,5.0in font "Helvetica,12"
set output output_path

set border lw 1.1 lc rgb "#30343b"
set tics in scale 0.9,0.45 font "Helvetica,13" textcolor rgb "#30343b"
set grid xtics ytics back lc rgb "#65717f" lw 1.1 dt 3
set xlabel "#Servers" font "Helvetica,14" offset 0,0.3
set ylabel "Latency (ms)" font "Helvetica,14" offset -0.4,0
# Tiny edge padding keeps markers and SD caps at 4 and 10 fully visible.
set xrange [3.94:10.06]
set xtics ("4" 4, "7" 7, "10" 10) mirror
set logscale y 10
set yrange [70:6000]
set ytics ("75" 75, "100" 100, "150" 150, "200" 200, "300" 300, \
           "500" 500, "750" 750, "1000" 1000, "1500" 1500, \
           "2000" 2000, "3000" 3000, "4000" 4000, "5000" 5000) mirror
set mytics 2
unset x2tics
unset y2tics
set format y "%g"
set lmargin 11.4
set rmargin 2.5
set tmargin 1.7
set bmargin 4.2

# Keep the legend above the data, with an opaque background for clarity.
set key at graph 0.018,0.982 left top opaque box \
    samplen 2.0 spacing 1.2 width -0.8 font "Helvetica,12"
set label 1 "Y-axis in logarithmic scale" at graph 0.98,0.97 right front \
    font "Helvetica,9" textcolor rgb "#737982"

set style line 1 lc rgb "#0072B2" lw 2.1 pt 7 ps 1.05
set style line 2 lc rgb "#009E73" lw 2.1 pt 5 ps 1.15
set style line 3 lc rgb "#D55E00" lw 2.1 pt 9 ps 1.15
set style line 4 lc rgb "#CC79A7" lw 2.1 pt 11 ps 1.15
set bars 4

docs = "10 100 1000 10000"
labels = "10 100 1k 10k"

# Source columns: replicas=1, docs=3, metric=4, mean_ms=6, sd_ms=7.
# Keep only total-latency rows so the intervening phase rows do not break lines.
# Filtered columns: replicas=1, mean_ms=2, sd_ms=3.
# The vertical bars show mean +/- one sample standard deviation.
plot for [i=1:4] sprintf("< awk -F '\\t' '$4==\"total_latency\" && $3==%s {print $1, $6, $7}' '%s'", word(docs,i), input_path) \
        using 1:2:($2-$3):($2+$3) with yerrorbars ls i lw 1.25 pt 0 notitle, \
     for [i=1:4] sprintf("< awk -F '\\t' '$4==\"total_latency\" && $3==%s {print $1, $6, $7}' '%s'", word(docs,i), input_path) \
        using 1:2 with linespoints ls i title sprintf("%s Docs Returned", word(labels,i))

unset output
