if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/final_results_update_latency/update_latency_by_replicas_summary.tsv"
}

if (!exists("output_dir")) {
    output_dir = "benchmarkSSE/results/final_results_update_latency/plots"
}

if (!exists("doc_count_values")) {
    doc_count_values = "1000 5000 10000 15000"
}

if (!exists("doc_count_labels")) {
    doc_count_labels = "1k 5k 10k 15k"
}

if (!exists("plot_font")) {
    plot_font = "Helvetica"
}

if (!exists("plot_font_size")) {
    plot_font_size = 18
}

doc_count_count = words(doc_count_values)
plot_font_spec = sprintf("%s,%d", plot_font, plot_font_size)
plot_label_font_spec = sprintf("%s,%d", plot_font, plot_font_size + 2)

set datafile separator "\t"
if (!exists("output_format")) {
    output_format = "pdf"
}

if (output_format eq "pdf") {
    output_ext = "pdf"
    set terminal pdfcairo enhanced color size 7.0in,4.0in font plot_font_spec
} else {
    output_ext = "png"
    set terminal pngcairo size 980,560 enhanced font plot_font_spec
}

set border lw 1.2
set tics out nomirror font plot_font_spec
set style line 81 lc rgb "#cfcfcf" lt 1 lw 1.1
set grid back xtics ytics ls 81
set key left top opaque box width 0 samplen 2.1 spacing 1.08 font plot_font_spec
set xlabel "SSE replicas" font plot_label_font_spec
set ylabel "Time (s)" font plot_label_font_spec
set lmargin 10
set bmargin 4.8
set xtics ("4" 4, "7" 7, "10" 10) nomirror
set ytics nomirror
set xrange [4:10]
set logscale y 10
set yrange [5:800]
unset mytics
unset ytics
set ytics nomirror
set for [v in "5 10 30 50 100 200 400 800"] ytics add (sprintf("%g", real(v)) real(v))
set label 1 "Y-axis in logarithmic scale" at graph 0.98, 0.94 right front font sprintf("%s,%d", plot_font, plot_font_size - 3) tc rgb "#555555"

set style line 1 lc rgb "#d95f02" lt 1 lw 1.45 pt 7 ps 1.55
set style line 2 lc rgb "#1b9e77" lt 1 lw 1.45 pt 5 ps 1.55
set style line 3 lc rgb "#7570b3" lt 1 lw 1.45 pt 9 ps 1.55
set style line 4 lc rgb "#e7298a" lt 1 lw 1.05 pt 11 ps 1.45
set style line 5 lc rgb "#66a61e" lt 1 lw 1.4 pt 13 ps 1.35
set style line 6 lc rgb "#e6ab02" lt 1 lw 1.4 pt 4 ps 1.35
set style line 7 lc rgb "#a6761d" lt 1 lw 1.4 pt 6 ps 1.35
set style line 8 lc rgb "#666666" lt 1 lw 1.4 pt 8 ps 1.35

set output sprintf("%s/update_latency_by_replicas.%s", output_dir, output_ext)
unset title
plot for [i=1:doc_count_count] sprintf("< awk -F'\\t' 'NR > 1 && ($1 == 4 || $1 == 7 || $1 == 10) && $7 == \"total_latency\" && $3 == \"%s\" { print $1 \"\\t\" $10 / 1000 }' %s | sort -n", word(doc_count_values, i), input_path) using 1:2 with linespoints ls i title sprintf("%s Docs/Update", word(doc_count_labels, i))

unset output
