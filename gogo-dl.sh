#!/bin/bash

# GoGoAnime.com downloader
#
# Tomas Cech <tcech@suse.cz>
#
#
# TODO:
#   - support more video sources than video44 and yourupload

# user agent (browser identification) sent to servers
USER_AGENT='Mozilla/5.0 (X11; Linux x86_64; rv:16.0) Gecko/20100101 Firefox/16.0'

# limit transfer rate
RATE="300k"

# which video provider is prefered, lower index means better
# name must correspond to function names is_iframe_* (e.g. is_iframe_video44)
# these function should work for both single URL and multiple URLs separated by spaces
PROVIDERS_PRIORITY=( video44 yourupload )


GREEN="\033[01;32m"
RED="\033[01;31m"
NONE="\033[00m"

inform() {
    local FIRST="$1"
    shift
    echo -e "${GREEN}$FIRST${NONE}" "$@"
}

error() {
    local FIRST="$1"
    shift
    echo -e "${RED}$FIRST${NONE}" "$@"
}

dependency_check() {
    for prog in xmllint wget sed grep; do
	if ! which "$prog" &> /dev/null; then
	    error "This script needs $prog installed."
	    exit 1
	fi
    done
}

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
	inform "Processing $VIDEO"
	process_gogo_video "$VIDEO"
    done
}

process_gogo_category() {
# $1	gogo category page

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
	    inform "Processing category page $PAGE"
	    process_gogo_category_page "$PAGE"
	done

	# clean the mess
	rm "$TMP"
    fi
}

provider_pick() {
# $1	provider to pick videos
#
# is REGEXP_REMATCH option here instead of another for cycle?
# it would have bigger requirements for regexp match
    local LINK
    for LINK in "${LINKS[@]}"; do
	if "is_iframe_$PROVIDER" "$LINK"; then
	    PROVIDER_URLS[${#PROVIDER_URLS[@]}]="$LINK"
	fi
    done
}

process_iframe_links() {
# $1	gogo page as referer
#
# We need to sort iframe links according to priority.
# 1] some video providers are prefered over others due to quality
# 2] there may be multiple iframes of the same video provider meaning
#    that video is multipart

    local PROVIDER_URLS
    local PROVIDER_FAILED

    # try providers in order defined by priority
    for PROVIDER in "${PROVIDERS_PRIORITY[@]}"; do
	PROVIDER_URLS=( )

	# is this provider even present?
	if "is_iframe_$PROVIDER" "${LINKS[*]}"; then
	    # yes, so lets pick URLs of this provider only
	    # it fills PROVIDER_URLS array
	    provider_pick "$PROVIDER"

	    # go throught picked provider URLs and get direct video URLs
	    PROVIDER_FAILED=""
	    for PROVIDER_URL in "${PROVIDER_URLS[@]}"; do
		if ! "process_$PROVIDER" "$PROVIDER_URL" "$1"; then
		    # obtaining video URL failed
		    PROVIDER_FAILED=yes
		    break
		fi
	    done

	    # if we got direct video URLs, we can stop looking for others
	    if [ -z "$PROVIDER_FAILED" ]; then
		break
	    fi
	fi
    done
}

process_gogo_video() {
# $1	gogo page

    #local 
    LINKS=( )
    local TMP=$(mktemp)
    local line

    # download page
    wget -U "$USER_AGENT" "$1" -O "$TMP"

    # find every source for iframe and fill LINKS variable
    while read line; do
	LINKS[${#LINKS[@]}]="$line"
    done < <(
	echo "cat //iframe/@src" |
	xmllint --shell --html "$TMP" 2>/dev/null | \
	# process src attributes, ignore facebook
	sed -n '/facebook/d;s/^ src="\([^"]\+\)"/\1/p'
    )

    # clean the mess
    rm "$TMP"

    # now go through iframe links and try to get direct link for download
    # TODO: this respects order on the page, but not video source preference, fix it
    # FIXME: if there are multiple parts of the same video provider, I should get them all

    process_iframe_links "$1"
}

is_iframe_video44() {
    [[ $1 =~ video44\.net ]]
}

process_video44() {
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
	inform "Got URL: $NEW_URL"
	URLS[${#URLS[@]}]="$NEW_URL"
	return 0
    else
	error "Error processing '$URL'"
	return 1
    fi
}

is_iframe_yourupload() {
    [[ $LINK =~ http://yourupload\.com/embed ]]
}

process_yourupload() {
# $1	URL
# $2	refrer

    local URL="$(sed 's/&amp;/\&/g' <<< "$1")"
    local TMP=$(mktemp)

    wgt "$URL" "$TMP" "$2"

    local NEW_URL="$(
        echo 'cat //embed/@flashvars' |
	xmllint --html --shell "$TMP" 2>/dev/null |
	sed -n 's@.*&amp;file=\(.*\.flv\)%3F.*@\1@p' |
	perl  -pe "s/\%([A-Fa-f0-9]{2})/pack('C', hex(\$1))/seg;"
	)"

    # clean the mess
    rm "$TMP"

    # if we got reasonable output, we have URL to download
    if [ "$NEW_URL" ]; then
	inform "Got URL: $NEW_URL"
	URLS[${#URLS[@]}]="$NEW_URL"
	return 0
    else
	error "Error processing '$URL'"
	return 1
    fi
}


process_gogo_queue() {
    # gather links from all the queue
    for PAGE in "$@"; do
	process_gogo "$PAGE"
    done

    if [ "$URLS" ]; then
	# we have some URLs, good
        # but we have them in reverse order
	local VIDEO_URLS=( )
	for i in $(seq $((${#URLS[@]} - 1)) -1 0); do
	    VIDEO_URLS[${#VIDEO_URLS[@]}]="${URLS[i]}"
	done

        # now download all the videos
	inform "Gathered links to videos:"
	for i in "${VIDEO_URLS[@]}"; do
	    echo "$i"
	done
	wget ${RATE:+--limit-rate="$RATE"} "${VIDEO_URLS[@]}"
    fi
}


#getopt
dependency_check
process_gogo_queue "$@"
