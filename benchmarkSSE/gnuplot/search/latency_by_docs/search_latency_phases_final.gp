# Run manually from the repository root:
#   gnuplot benchmarkSSE/gnuplot/search/latency_by_docs/search_latency_phases_final.gp
# Four linear panels keep small and large result sizes readable without
# distorting the proportions of stacked phases.

if (!exists("input_path")) {
    input_path = "benchmarkSSE/results/latency_final_2026_11_12/search_by_docs_final.tsv"
}
if (!exists("output_path")) {
    output_path = "benchmarkSSE/plots/final_latency/search_latency_phases.pdf"
}

# Pivot the long-form TSV in memory: server, docs, then four cumulative
# phase heights. No intermediate file is written.
phase_rows = sprintf("< awk -v OFMT='%%.9f' -F '\\t' 'NR>1 { k=$1 SUBSEP $3; if ($4==\"total_latency\") { order[++n]=k; rep[k]=$1; docs[k]=$3 }; v[k,$4]=$6 } END { for (i=1;i<=n;i++) { k=order[i]; d=docs[k]; s=v[k,\"normalization_latency\"]+v[k,\"state_request_latency\"]+v[k,\"address_resolution_latency\"]; o=s+v[k,\"oram_read_latency\"]; q=o+v[k,\"token_build_latency\"]+v[k,\"search_request_round_trip_latency\"]; p=q+v[k,\"result_processing_latency\"]; print rep[k],d,s,o,q,p } }' '%s'", input_path)

set terminal pdfcairo enhanced color size 8.5in,6.3in font "Helvetica,11"
set output output_path

set border lw 1.1 lc rgb "#30343b"
set tics in scale 0.9,0.45 font "Helvetica,10" textcolor rgb "#30343b"
set grid xtics ytics back lc rgb "#65717f" lw 0.9 dt 3
set xrange [2.65:11.35]
set xtics ("4" 4, "7" 7, "10" 10) mirror
unset x2tics
unset y2tics
set boxwidth 1.15 absolute
set style fill pattern 1 border lc rgb "#46515d"

docs = "10 100 1000 10000"
labels = "10 100 1k 10k"
ymaxes = "120 200 800 5000"
ysteps = "20 25 100 500"

set multiplot layout 2,2 margins 0.10,0.97,0.12,0.87 spacing 0.09,0.12
unset key

# A single page-wide legend with larger pattern samples and labels.
set object 101 rectangle from screen 0.115,0.935 to screen 0.160,0.955 \
    fc rgb "#4E79A7" fs pattern 1 border lc rgb "#46515d" front
set label 101 "Search Setup" at screen 0.170,0.945 left \
    font "Helvetica,13" textcolor rgb "#30343b" front
set object 102 rectangle from screen 0.335,0.935 to screen 0.380,0.955 \
    fc rgb "#59A14F" fs pattern 4 border lc rgb "#46515d" front
set label 102 "ORAM Read" at screen 0.390,0.945 left \
    font "Helvetica,13" textcolor rgb "#30343b" front
set object 103 rectangle from screen 0.530,0.935 to screen 0.575,0.955 \
    fc rgb "#F28E2B" fs pattern 5 border lc rgb "#46515d" front
set label 103 "Search Request" at screen 0.585,0.945 left \
    font "Helvetica,13" textcolor rgb "#30343b" front
set object 104 rectangle from screen 0.755,0.935 to screen 0.800,0.955 \
    fc rgb "#E15759" fs pattern 2 border lc rgb "#46515d" front
set label 104 "Result Processing" at screen 0.810,0.945 left \
    font "Helvetica,13" textcolor rgb "#30343b" front

do for [panel=1:4] {
    doc_count = real(word(docs,panel))
    ymax = real(word(ymaxes,panel))
    ystep = real(word(ysteps,panel))
    set title sprintf("%s Docs Returned", word(labels,panel)) font "Helvetica,12"
    set yrange [0:ymax]
    set ytics 0,ystep,ymax mirror

    if (panel == 1 || panel == 3) {
        set ylabel "Latency (ms)" font "Helvetica,12" offset 0,0
    } else {
        unset ylabel
    }
    if (panel > 2) {
        set xlabel "#Servers" font "Helvetica,12" offset 0,0.3
    } else {
        unset xlabel
    }
    # Draw cumulative boxes back-to-front to expose the four stacked phases.
    plot phase_rows using (($2==doc_count) ? $1 : 1/0):6 with boxes fc rgb "#E15759" fs pattern 2 notitle, \
         phase_rows using (($2==doc_count) ? $1 : 1/0):5 with boxes fc rgb "#F28E2B" fs pattern 5 notitle, \
         phase_rows using (($2==doc_count) ? $1 : 1/0):4 with boxes fc rgb "#59A14F" fs pattern 4 notitle, \
         phase_rows using (($2==doc_count) ? $1 : 1/0):3 with boxes fc rgb "#4E79A7" fs pattern 1 notitle

    if (panel == 1) {
        unset object 101; unset object 102; unset object 103; unset object 104
        unset label 101; unset label 102; unset label 103; unset label 104
    }
}

unset multiplot
unset output
