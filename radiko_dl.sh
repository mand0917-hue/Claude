#!/usr/bin/env bash
# radiko タイムフリー番組を ffmpeg で m4a として保存する
#
# 使い方:
#   ./radiko_dl.sh 'https://radiko.jp/share/?t=20260926090000&sid=KISSFMKOBE' [出力ファイル.m4a]
#   ./radiko_dl.sh KISSFMKOBE 20260926090000 [出力ファイル.m4a]
#
# 必要なもの: curl, ffmpeg, base64 (日本国内・放送エリア内のIPから実行すること)
set -euo pipefail

if [[ $# -lt 1 ]]; then
  sed -n '2,8p' "$0"; exit 1
fi

if [[ "$1" == http* ]]; then
  url="$1"; shift
  ft=$(sed -n 's/.*[?&]t=\([0-9]\{14\}\).*/\1/p' <<<"$url")
  sid=$(sed -n 's/.*[?&]sid=\([A-Za-z0-9_-]*\).*/\1/p' <<<"$url")
else
  sid="$1"; ft="$2"; shift 2
fi
[[ -n "${ft:-}" && -n "${sid:-}" ]] || { echo "URLから放送局/時刻を取得できません" >&2; exit 1; }

# --- 認証 (auth1 -> auth2) ---
authkey='bcd151073c03b352e1ef2fd66c32209da9ca0afa'
auth1=$(curl -sS -D - -o /dev/null https://radiko.jp/v2/api/auth1 \
  -H 'X-Radiko-App: pc_html5' -H 'X-Radiko-App-Version: 0.0.1' \
  -H 'X-Radiko-User: dummy_user' -H 'X-Radiko-Device: pc' | tr -d '\r')
token=$(awk -F': ' 'tolower($1)=="x-radiko-authtoken"{print $2}' <<<"$auth1")
offset=$(awk -F': ' 'tolower($1)=="x-radiko-keyoffset"{print $2}' <<<"$auth1")
length=$(awk -F': ' 'tolower($1)=="x-radiko-keylength"{print $2}' <<<"$auth1")
[[ -n "$token" ]] || { echo "auth1 に失敗しました" >&2; exit 1; }
partialkey=$(printf '%s' "${authkey:$offset:$length}" | base64)

area=$(curl -sS https://radiko.jp/v2/api/auth2 \
  -H "X-Radiko-AuthToken: $token" -H "X-Radiko-Partialkey: $partialkey" \
  -H 'X-Radiko-User: dummy_user' -H 'X-Radiko-Device: pc' | tr -d '\r\n')
echo "エリア: $area"
[[ "$area" == JP* ]] || { echo "auth2 に失敗しました (日本国内から実行してください)" >&2; exit 1; }

# --- 番組情報 (終了時刻・タイトル) ---
# 放送日は 5:00 区切りなので 0〜4時台の番組は前日の番組表に載る
day=${ft:0:8}
if (( 10#${ft:8:2} < 5 )); then
  day=$(date -d "${ft:0:8} -1 day" +%Y%m%d 2>/dev/null || date -j -v-1d -f %Y%m%d "${ft:0:8}" +%Y%m%d)
fi
xml=$(curl -sS "https://radiko.jp/v3/program/station/date/${day}/${sid}.xml")
prog=$(tr -d '\n' <<<"$xml" | grep -o "<prog [^>]*ft=\"${ft}\"[^>]*>.*" | sed 's#</prog>.*##')
to=$(sed -n 's/.* to="\([0-9]\{14\}\)".*/\1/p' <<<"${prog%%>*}")
title=$(sed -n 's#.*<title>\([^<]*\)</title>.*#\1#p' <<<"$prog" | head -1)
[[ -n "$to" ]] || { echo "番組が見つかりません: $sid $ft" >&2; exit 1; }
echo "番組: ${title:-不明} (${ft} - ${to})"

out="${1:-${sid}_${ft}_${title//[\/:*?\"<>|]/_}.m4a}"

# --- ダウンロード ---
lsid=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
ffmpeg -hide_banner -loglevel warning -stats \
  -headers "X-Radiko-AuthToken: ${token}"$'\r\n' \
  -i "https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=${sid}&l=15&ft=${ft}&to=${to}&lsid=${lsid}" \
  -vn -c:a copy -bsf:a aac_adtstoasc \
  -metadata title="${title}" -metadata artist="${sid}" -metadata date="${ft:0:4}" \
  -y "$out"

echo "保存しました: $out"
