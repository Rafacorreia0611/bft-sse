if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/data/update_latency_by_replicas_summary.tsv"
}

if (!exists("output_dir")) {
    output_dir = "benchmarkSSE/plots"
}

if (!exists("doc_count_values")) {
    doc_count_values = "1000 5000 10000 15000"
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
set terminal pdfcairo enhanced color size 7.0in,4.0in font plot_font_spec

set border lw 1.2
set tics out nomirror font plot_font_spec
set style line 81 lc rgb "#cfcfcf" lt 1 lw 1.1
set grid back xtics ytics ls 81
set key left top opaque box width 1 samplen 2.2 spacing 1.1 font plot_font_spec
set xlabel "SSE replicas" font plot_label_font_spec
set ylabel "Time (ms)" font plot_label_font_spec
set lmargin 12
set bmargin 4.8
set logscale y 10
set xtics 1 nomirror
set xrange [*:*]
set offsets 0.2,0.2,0,0
set yrange [1:*]
set format x "%g"
set format y "%g"

set style line 1 lc rgb "#d95f02" lt 1 lw 1.6 pt 7 ps 1.35
set style line 2 lc rgb "#1b9e77" lt 1 lw 1.6 pt 5 ps 1.35
set style line 3 lc rgb "#7570b3" lt 1 lw 1.6 pt 9 ps 1.35
set style line 4 lc rgb "#e7298a" lt 1 lw 1.25 pt 11 ps 1.25
set style line 5 lc rgb "#66a61e" lt 1 lw 1.25 pt 13 ps 1.20
set style line 6 lc rgb "#e6ab02" lt 1 lw 1.25 pt 4 ps 1.20
set style line 7 lc rgb "#a6761d" lt 1 lw 1.25 pt 6 ps 1.20
set style line 8 lc rgb "#666666" lt 1 lw 1.25 pt 8 ps 1.20

set output sprintf("%s/update_latency_by_replicas.pdf", output_dir)
unset title
plot for [i=1:doc_count_count] sprintf("< awk -F'\\t' 'NR > 1 && $7 == \"total_latency\" && $3 == \"%s\" { print $1 \"\\t\" $10 }' %s | sort -n", word(doc_count_values, i), input_path) using 1:2 with linespoints ls i title sprintf("%s Docs/Update", word(doc_count_values, i))

unset output
