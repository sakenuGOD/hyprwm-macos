#!/bin/zsh
# Пересоздать дампы символов и дизасма SkyLight (после ребута /tmp пуст).
E=~/Developer/re-tools/extracted/SkyLight
nm "$E" | awk '{print $1"\t"$3}' > /tmp/sl_raw.tsv
cut -f2 /tmp/sl_raw.tsv | c++filt -_ > /tmp/sl_dem.txt
cut -f1 /tmp/sl_raw.tsv | sed 's/^0*//' | paste - /tmp/sl_dem.txt > /tmp/sl_map.tsv
otool -tvV "$E" > /tmp/sl_dis.txt
echo "sl_map.tsv $(wc -l < /tmp/sl_map.tsv) строк; sl_dis.txt $(wc -l < /tmp/sl_dis.txt) строк"
