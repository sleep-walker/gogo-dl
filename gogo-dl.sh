#!/bin/bash

# GoGoAnime.com downloader
#
# Tomas Cech <tcech@suse.cz>
#
#
# TODO:
#   - support more video sources than video44
#   - add category parsing

USER_AGENT='Mozilla/5.0 (X11; Linux x86_64; rv:16.0) Gecko/20100101 Firefox/16.0'
RATE="300k"

wgt() {
# $1	URL
# $2	file
# $3	referer

    wget -U "$USER_AGENT" ${RATE:+--limit-rate="$RATE"} "$1" ${3:+--referer="$3"} -O "$2"
}

process_gogo() {
    if [[ $1 =~ http://www\.gogoanime\.com/category/ ]]; then
        # we may download whole category with single command
	process_gogo_category "$1"
    else
	# or process just single video
	process_gogo_video "$1"
    fi
}

process_gogo_category_page() {
# $1	category page
    local TMP=$(mktemp)
    local VIDEOS=( )
    local VIDEO

    # get category page
    wgt "$1" "$TMP"

    # find URLs to pages with video
    while read line; do
	VIDEOS[${#VIDEOS[@]}]="$line"
    done < <(
	echo 'cat //tr/td/a/@href' |
	xmllint --html --shell "$TMP" 2>/dev/null |
	sed -n 's/^ href="\([^"]\+\)"/\1/p'
    )

    # clean the mess
    rm "$TMP"

    for VIDEO in "${VIDEOS[@]}"; do
	process_gogo_video "$VIDEO"
    done
}

process_gogo_category() {
    # cat //tr/td/a/@href - links
    # cat //div[@class='wp-pagenavi']/a/@href - pages
    # TODO: not implemented yet
    if [[ $1 =~ http://www.gogoanime.com/category/[^/]+/page/[0-9]+ ]]; then
	# download some exact category page
	process_gogo_category_page "$1"
    elif [[ $1 =~ http://www.gogoanime.com/category/[^/]+$ ]]; then
	# download whole category
	local TMP=$(mktemp)
	local line

	# get first page (always present)
	wgt "${1%/}/page/1" "$TMP"


	local PAGES=( "${1%/}/page/1" )

	# extract page URLs
	while read line; do
	    PAGES[${#PAGES[@]}]="$line"
	done < <(
	    echo "cat //div[@class='wp-pagenavi']/a/@href" |
	    xmllint --html --shell 1 2>/dev/null |
	    sed -n 's/^ href="\([^"]\+\)"/\1/p' |
	    sort -u
	)

	# process every page
	for PAGE in "${PAGES[@]}"; do
	    process_gogo_category_page "$PAGE"
	done
    fi
    rm "$TMP"
}

process_gogo_video() {
# $1	gogo page

    local LINKS=( )
    local TMP=$(mktemp)
    local line

    # download page
    wget -U "$USER_AGENT" "$1" -O "$TMP"

    # find every source for iframe and fill LINKS variable
    while read line; do
	LINKS[${#LINKS}]="$line"
    done < <(
	echo "cat //iframe/@src" | xmllint --shell --html "$TMP" 2>/dev/null | \
	# process src attributes, ignore facebook
	sed -n '/facebook/d;s/^ src="\([^"]\+\)"/\1/p'
    )

    # clean the mess
    rm "$TMP"

    # now go through iframe links and try to get direct link for download
    # TODO: this respects order on the page, but not video source preference, fix it
    for LINK in "${LINKS[@]}"; do
	    if [[ $LINK =~ video44\.net ]] && video44 "$LINK" "$1"; then
		# we have video from the PAGE, we can continue with other
		break;
	    fi
    done
    
}

video44() {
# $1	URL
# $2	referer

    local URL="$(sed 's/&amp;/\&/g' <<< "$1")"
    local TMP=$(mktemp)

    # download frame
    wgt "$URL" "$TMP" "$2"

    # get information from the frame
    local NEW_URL="$(
	echo 'cat /html/body/div/object/param[@name="flashvars"]' |
	xmllint --shell --html "$TMP" 2>/dev/null |
	sed -n 's/.*;file=\([^;]\+\)&amp;.*/\1/p' |
	perl  -pe "s/\%([A-Fa-f0-9]{2})/pack('C', hex(\$1))/seg;"
    	)"

    # clean the mess
    rm "$TMP"

    # if we got reasonable output, we have URL to download
    if [ "$NEW_URL" ]; then
	echo "Got URL: $NEW_URL"
	URLS[${#URLS[@]}]="$NEW_URL"
	return 0
    else
	echo "Error processing '$URL'"
	return 1
    fi
}

process_gogo_queue() {
    # gather links from all the queue
    for PAGE in "$@"; do
	process_gogo "$PAGE"
    done

    if [ "$URLS" ]; then
    # now download all the videos
	wget ${RATE:+--limit-rate="$RATE"} "${URLS[@]}"
    fi
}


#getopt
process_gogo_queue "$@"
