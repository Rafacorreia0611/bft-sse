if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/data/search_latency_by_replicas_summary.tsv"
}

if (!exists("output_dir")) {
    output_dir = "benchmarkSSE/plots"
}

if (!exists("bucket_specs")) {
    bucket_specs = "10:10 100:100 1000:1000 10000:10000"
}

if (!exists("bucket_labels")) {
    bucket_labels = "10 100 1k 10k"
}

if (!exists("plot_font")) {
    plot_font = "Helvetica"
}

if (!exists("plot_font_size")) {
    plot_font_size = 18
}

bucket_count = words(bucket_specs)
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
set key left top opaque box width -0.4 samplen 1.7 spacing 1.1 font plot_font_spec
set xlabel "SSE replicas" font plot_label_font_spec
set ylabel "Time (ms)" font plot_label_font_spec
set lmargin 12
set bmargin 4.8
set xtics 1 nomirror
set ytics nomirror
set xrange [*:*]
set offsets 0.2,0.2,0,0
set logscale y 10
set yrange [*:*]
unset mytics

set style line 1 lc rgb "#d95f02" lt 1 lw 1.45 pt 7 ps 1.45
set style line 2 lc rgb "#1b9e77" lt 1 lw 1.45 pt 5 ps 1.45
set style line 3 lc rgb "#7570b3" lt 1 lw 1.45 pt 9 ps 1.45
set style line 4 lc rgb "#e7298a" lt 1 lw 1.05 pt 11 ps 1.35
set style line 5 lc rgb "#66a61e" lt 1 lw 2.4 pt 13 ps 1.25
set style line 6 lc rgb "#e6ab02" lt 1 lw 2.4 pt 4 ps 1.25
set style line 7 lc rgb "#a6761d" lt 1 lw 2.4 pt 6 ps 1.25
set style line 8 lc rgb "#666666" lt 1 lw 2.4 pt 8 ps 1.25

set output sprintf("%s/search_latency_by_replicas.%s", output_dir, output_ext)
unset title
plot for [i=1:bucket_count] sprintf("< awk -F'\\t' 'NR > 1 && $6 == \"total_latency\" && $3 == \"%s\" { print $1 \"\\t\" $10 }' %s", word(bucket_specs, i), input_path) using 1:2 with linespoints ls i title sprintf("%s Docs Returned", word(bucket_labels, i))

unset output
