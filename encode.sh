#!/bin/bash
shopt -s nocasematch
#TR_APP_VERSION
#TR_TIME_LOCALTIME
#TR_TORRENT_DIR
#TR_TORRENT_HASH
#TR_TORRENT_ID
#TR_TORRENT_NAME
#id="${TR_TORRENT_ID}";
hash="${TR_TORRENT_HASH^^}";
name="${TR_TORRENT_NAME}";
dir="${TR_TORRENT_DIR}/${name}";
date=`date`

TRANSMISSION_USERNAME="username";
TRANSMISSION_PASSWORD="password"

PREFIX="ENCODETOSTREAM";

# if we are dealing with a movie, we should concatenate the possibly separated movie file
# if we are dealing with a tv show with multiple episodes we should not concatenate all of the files together
CONCAT_FILES=false;

echo "env TR_TORRENT_HASH='$TR_TORRENT_HASH' \\
env TR_TORRENT_NAME='$TR_TORRENT_NAME' \\
env TR_TORRENT_DIR='$TR_TORRENT_DIR' \\
/home/encode/encode.sh #$date" >> /home/encode/call.log

outputdir="/home/encodes/${hash}";

logfile="/home/encode/logs/${hash}.log";

# make a backup of the .torrent file
torrentlogfile="/home/encode/torrents/${hash}.torrent";
torrentid="${hash:0:16}";
torrentid="${torrentid,,}";
torrentdir="${dir}/../../.config/transmission-daemon/torrents/";
torrentfile="${torrentdir}${name}.${torrentid}.torrent";
cp "${torrentfile}" "${torrentlogfile}"

touch "${logfile}"

if [ ! -f "${logfile}" ]; then
	echo "${PREFIX}_ENCODE_FAIL Could not create log file";
	exit;
fi

function join_by { local IFS="$1"; shift; echo "$*"; }

[ ! -e "${outputdir}" ] && mkdir "${outputdir}";

if [ ! -d "${outputdir}" ]; then
        echo "${PREFIX}_ENCODE_FAIL Could not create output directory" >> $logfile
        exit;
fi

echo "${PREFIX}_ENCODE_START `date +%s` (${date}) " >> $logfile
echo "${PREFIX}_ENCODE_INPUT_NAME ${name}" >> $logfile
echo "${PREFIX}_ENCODE_INPUT_DIR ${dir}" >> $logfile
echo "${PREFIX}_ENCODE_OUTPUT_DIR ${outputdir}" >> $logfile
echo "${PREFIX}_ENCODE_LOG_FILE ${logfile}" >> $logfile

echo "${PREFIX}_ENCODE_CONCAT_FILES ${CONCAT_FILES}" >> $logfile

# comment this if you want to keep seeding, this is becuase the seed to ratio 0 doesn't seem to work
echo "${PREFIX}_ENCODE_STOPPING_TORRENT $(transmission-remote 127.0.0.1:9100 --auth=${TRANSMISSION_USERNAME}:${TRANSMISSION_PASSWORD} -t ${hash} --stop)" >> $logfile # just to be sure

# process: mp4,mkv,avi
#echo "Looking for mp4/mkv/avi";
i=0;
[ ! -d "${dir}" ] && echo "${PREFIX}_ENCODE_FAIL Torrent directory does not exist" >> $logfile && exit
cd "${dir}";
if [[ $(find ./ -name '*.mp4' -or -name '*.mkv' -or -name '*.avi' -or -name '*.m4v') ]]; then
	files="$(find ./ -name '*.mp4' -or -name '*.mkv' -or -name '*.avi' -or -name '*.m4v')";
else
	echo "${PREFIX}_ENCODE_FAIL Could not find any suitable encodable files" >> $logfile
	exit;
fi
echo "${PREFIX}_ENCODE_FILES_COUNT $(echo "$files" | wc -l)" >> $logfile

echo "${PREFIX}_ENCODE_FILE_LIST_START
$files
${PREFIX}_ENCODE_FILE_LIST_END" >> $logfile;

while read -r f; do

	i=$(($i+1));

	echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_FILE $f" >> $logfile;
	echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_FORMAT ${f: -4}" >> $logfile;

	if [[ "$f" =~ "sample" ]]; then # make case insensitive
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_IS_SAMPLE TRUE" >> $logfile
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_IGNORING_SAMPLES TRUE" >> $logfile
		i=$(($i-1));
	else
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_IS_SAMPLE FALSE" >> $logfile

		file="${f}";

		if [[ $(mediainfo --Output=Video\;%BitRate% "${file}") ]] && [[ $(mediainfo --Output=Audio\;%BitRate% "${file}") ]]; then
		        AudioBitrate=$(mediainfo --Output=Audio\;%BitRate% "${file}");
		        VideoBitrate=$(mediainfo --Output=Video\;%BitRate% "${file}");
		        OverallBitrate=$(mediainfo --Output=General\;%OverallBitRate% "${file}");
		else
        		OverallBitrate=$(mediainfo --Output=General\;%OverallBitRate% "${file}");
        		AudioBitrate=$(echo "scale=0; ${OverallBitrate} / (10/1)" | bc -l); #AudioBitrate=$(printf "%.$2f" "${AudioBitrate}");
        		VideoBitrate=$(echo "scale=0; ${OverallBitrate} / (10/9)" | bc -l); #VideoBitrate=$(printf "%.$2f" "${VideoBitrate}");
		fi

		AudioBitrate=$(( ${AudioBitrate} / 1000 ));
		VideoBitrate=$(( ${VideoBitrate} / 1000 ));
		OverallBitrate=$(( ${OverallBitrate} / 1000 ));

		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_BITRATE ${AudioBitrate}" >> $logfile
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_VIDEO_BITRATE ${VideoBitrate}" >> $logfile
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_OVERALL_BITRATE ${OverallBitrate}" >> $logfile

		Height=$(mediainfo --Output=Video\;%Height% "${file}");
		FrameRate=$(mediainfo --Output=Video\;%FrameRate% "${file}");

		AudioChannels=$(mediainfo --Output=Audio\;%Channels% "${file}");

		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_HEIGHT ${Height}" >> $logfile
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_FRAME_RATE ${FrameRate}" >> $logfile
		echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS ${AudioChannels}" >> $logfile

		Encode1080=false;
		Encode720=false;
		Encode480=false;

		# options
		# 1080
		# 1080-LOW
		# 720
		# 720-LOW
		# 480
		# 480-LOW
		# LOW
		# RAW

		if [ $(echo "${FrameRate}>25" | bc -l) = 1 ]; then # if the frame rate is higher than 25 frames per second, then limit it to 25, otherwise use the original frame rate
        		FrameRate=25;
			echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_FRAME_RATE_FORCED TRUE" >> $logfile
		fi

		if [ "${Height}" -ge 1050 ]; then # a little leeway
        		FHD_VIDEO_BITRATE=4000;
        		FHD_AUDIO_BITRATE=256;
        		FHD_AUDIO_CHANNELS=2;

        		Encode1080=true;

        		if [ "${AudioChannels}" -ge "${FHD_AUDIO_CHANNELS}" ]; then
        		        AudioChannels="${FHD_AUDIO_CHANNELS}";
        		fi

        		if [ "${VideoBitrate}" -ge "${FHD_VIDEO_BITRATE}" ]; then
        		        echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 1080, V: ${FHD_VIDEO_BITRATE}k, A: ${AudioChannels} channel(s) ${FHD_AUDIO_BITRATE}k, F: ${FrameRate} [TRUE F-HD]" >> $logfile
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]=1080;
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${FHD_VIDEO_BITRATE}";
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${AudioChannels}";
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${FHD_AUDIO_BITRATE}";
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${FrameRate}";
				ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${i}-1080.mp4";
                                ENCODING_SETTINGS_FHD[${#ENCODING_SETTINGS_FHD[@]}]="${file}";
        		else
        		        echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 1080, V: ${VideoBitrate}k, A: ${AudioChannels} channel(s) ${AudioBitrate}k, F: ${FrameRate} [LOW BITRATE F-HD]" >> $logfile
				ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]=1080;
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${VideoBitrate}";
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${AudioBitrate}";
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${i}-1080-LOW.mp4";
                                ENCODING_SETTINGS_FHD_LOW[${#ENCODING_SETTINGS_FHD_LOW[@]}]="${file}";
        		fi
		fi

		if [ "${Height}" -ge 700 ]; then # again a little leeway
        		HDR_VIDEO_BITRATE=1500;
        		HDR_AUDIO_BITRATE=128;
        		HDR_AUDIO_CHANNELS=2;

        		Encode720=true;

        		if [ "${AudioChannels}" -ge "${HDR_AUDIO_CHANNELS}" ]; then
        		        AudioChannels="${HDR_AUDIO_CHANNELS}";
        		fi

        		if [ "${VideoBitrate}" -ge "${HDR_VIDEO_BITRATE}" ]; then
        		        echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 720, V: ${HDR_VIDEO_BITRATE}k, A: ${AudioChannels} channel(s) ${HDR_AUDIO_BITRATE}k, F: ${FrameRate} [TRUE HD-R]" >> $logfile
				ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]=720;
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${HDR_VIDEO_BITRATE}";
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${HDR_AUDIO_BITRATE}";
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${i}-720.mp4";
                                ENCODING_SETTINGS_HDR[${#ENCODING_SETTINGS_HDR[@]}]="${file}";
        		else
        		        echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 720, V: ${VideoBitrate}k, A: ${AudioChannels} channel(s) ${AudioBitrate}k, F: ${FrameRate} [LOW BITRATE HD-R]" >> $logfile
				ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]=720;
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${VideoBitrate}";
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${AudioBitrate}";
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${i}-720-LOW.mp4";
                                ENCODING_SETTINGS_HDR_LOW[${#ENCODING_SETTINGS_HDR_LOW[@]}]="${file}";
        		fi
		fi

		if [ "${Height}" -ge 480 ]; then # no point with leeway here becuase the alternative will use same bitrates
		        SD_VIDEO_BITRATE=800;
		        SD_AUDIO_BITRATE=64;
		        SD_AUDIO_CHANNELS=1;

		        Encode480=true;

		        AudioChannels="${SD_AUDIO_CHANNELS}"; # FORCE 1 channel

		        if [ "${VideoBitrate}" -ge "${SD_VIDEO_BITRATE}" ]; then
		                echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 480, V: ${SD_VIDEO_BITRATE}k, A: ${AudioChannels} channel(s) ${SD_AUDIO_BITRATE}k, F: ${FrameRate} [TRUE SD]" >> $logfile
				ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]=480;
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${SD_VIDEO_BITRATE}";
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${SD_AUDIO_BITRATE}";
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${i}-480.mp4";
                                ENCODING_SETTINGS_SD[${#ENCODING_SETTINGS_SD[@]}]="${file}";
		        else
		                echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: 480, V: ${VideoBitrate}k, A: ${AudioChannels} channel(s) ${AudioBitrate}k, F: ${FrameRate} [LOW BITRATE SD]" >> $logfile
				ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]=480;
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${VideoBitrate}";
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${AudioBitrate}";
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${i}-480-LOW.mp4";
                                ENCODING_SETTINGS_SD_LOW[${#ENCODING_SETTINGS_SD_LOW[@]}]="${file}";
		        fi
		fi

		if [ "${Encode1080}" = false ] && [ "${Encode720}" = false ] && [ "${Encode480}" = false ]; then
		        #echo "Oh dear, our formats seem insufficient for this file";

		        LOW_VIDEO_BITRATE=800;
		        LOW_AUDIO_BITRATE=64;
		        LOW_AUDIO_CHANNELS=1;

		        AudioChannels="${LOW_AUDIO_CHANNELS}"; # FORCE 1 channel

		        if [ "${VideoBitrate}" -ge "${LOW_VIDEO_BITRATE}" ]; then
		                echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: ${Height}, V: ${LOW_VIDEO_BITRATE}k, A: ${AudioChannels} channel(s) ${LOW_AUDIO_BITRATE}k, F: ${FrameRate} [LOW]" >> $logfile
				ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${Height}";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${LOW_VIDEO_BITRATE}";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${LOW_AUDIO_BITRATE}";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${i}-LOW.mp4";
                                ENCODING_SETTINGS_LOW[${#ENCODING_SETTINGS_LOW[@]}]="${file}";
		        else
		                echo "${PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: ${Height}, V: ${VideoBitrate}k, A: ${AudioChannels} channel(s) ${AudioBitrate}k, F: ${FrameRate} [RAW]" >> $logfile
				ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${Height}";
                                ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${VideoBitrate}";
                                ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${AudioChannels}";
                                ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${AudioBitrate}";
                                ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${FrameRate}";
                                ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${i}-RAW.mp4";
				ENCODING_SETTINGS_RAW[${#ENCODING_SETTINGS_RAW[@]}]="${file}";
		        fi
		fi
	fi
done <<< "$files"

# encode lower qualities first, they should be faster i think?

# could implement intel qsv encoding filters, however for now we are not encoding on a compatible CPU

# RAW Video
if [ "${#ENCODING_SETTINGS_RAW[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING RAW" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_RAW[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_RAW[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_RAW[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_RAW[$x+3]}k" -ac "${ENCODING_SETTINGS_RAW[$x+2]}" \
	                -r "${ENCODING_SETTINGS_RAW[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_RAW[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_RAW[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_RAW[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_RAW[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_RAW[$x+5]}.ts";
			fi

        	x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_RAW[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-RAW.mp4.tmp' -or -name '*-RAW.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# Low Quality Video
if [ "${#ENCODING_SETTINGS_LOW[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING LOW" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_LOW[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_LOW[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_LOW[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_LOW[$x+3]}k" -ac "${ENCODING_SETTINGS_LOW[$x+2]}" \
	                -r "${ENCODING_SETTINGS_LOW[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_LOW[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_LOW[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_LOW[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_LOW[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_LOW[$x+5]}.ts";
			fi

	        x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_LOW[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-LOW.mp4.tmp' -or -name '*-LOW.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# Low Bitrate SD 480p
if [ "${#ENCODING_SETTINGS_SD_LOW[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING SD_LOW" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_SD_LOW[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_SD_LOW[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_SD_LOW[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_SD_LOW[$x+3]}k" -ac "${ENCODING_SETTINGS_SD_LOW[$x+2]}" \
	                -r "${ENCODING_SETTINGS_SD_LOW[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_SD_LOW[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_SD_LOW[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_SD_LOW[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_SD_LOW[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_SD_LOW[$x+5]}.ts";
			fi

        	x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_SD_LOW[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-480-LOW.mp4.tmp' -or -name '*-480-LOW.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# SD 480p [SD]
if [ "${#ENCODING_SETTINGS_SD[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING SD" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_SD[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_SD[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_SD[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_SD[$x+3]}k" -ac "${ENCODING_SETTINGS_SD[$x+2]}" \
	                -r "${ENCODING_SETTINGS_SD[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_SD[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_SD[$x+5]}.tmp" &>> $logfile

	        if [ "${CONCAT_FILES}" = true ]; then
			ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_SD[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_SD[$x+5]}.ts" &>> $logfile
			CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_SD[$x+5]}.ts";
		fi

	        x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_SD[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-480.mp4.tmp' -or -name '*-480.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# Low Bitrate HD 'Ready' 720p
if [ "${#ENCODING_SETTINGS_HDR_LOW[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING HDR_LOW" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_HDR_LOW[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_HDR_LOW[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_HDR_LOW[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_HDR_LOW[$x+3]}k" -ac "${ENCODING_SETTINGS_HDR_LOW[$x+2]}" \
	                -r "${ENCODING_SETTINGS_HDR_LOW[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_HDR_LOW[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_HDR_LOW[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_HDR_LOW[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_HDR_LOW[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_HDR_LOW[$x+5]}.ts";
			fi

	        x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_HDR_LOW[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-720-LOW.mp4.tmp' -or -name '*-720-LOW.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# HD 'Ready' 720p [HDR]
if [ "${#ENCODING_SETTINGS_HDR[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING HDR" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_HDR[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_HDR[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_HDR[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_HDR[$x+3]}k" -ac "${ENCODING_SETTINGS_HDR[$x+2]}" \
	                -r "${ENCODING_SETTINGS_HDR[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_HDR[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_HDR[$x+5]}.tmp" &>> $logfile

		if [ "${CONCAT_FILES}" = true ]; then
			ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_HDR[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_HDR[$x+5]}.ts" &>> $logfile
			CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_HDR[$x+5]}.ts";
		fi

        	x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_HDR[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-720.mp4.tmp' -or -name '*-720.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# Low Bitrate Full HD 1080p [FHD_LOW]
if [ "${#ENCODING_SETTINGS_FHD_LOW[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING FHD_LOW" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_FHD_LOW[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_FHD_LOW[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_FHD_LOW[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_FHD_LOW[$x+3]}k" -ac "${ENCODING_SETTINGS_FHD_LOW[$x+2]}" \
	                -r "${ENCODING_SETTINGS_FHD_LOW[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_FHD_LOW[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_FHD_LOW[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_FHD_LOW[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_FHD_LOW[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_FHD_LOW[$x+5]}.ts";
			fi

	        x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_FHD_LOW[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-1080-LOW.mp4.tmp' -or -name '*-1080-LOW.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

# Full HD 1080p [FHD]
if [ "${#ENCODING_SETTINGS_FHD[@]}" -gt 0 ]; then
	echo "${PREFIX}_ENCODE_STATUS ENCODING FHD" >> $logfile
	x=0;
	while [ "${x}" -lt "${#ENCODING_SETTINGS_FHD[@]}" ]; do
	        ffmpeg -i "${ENCODING_SETTINGS_FHD[$x+6]}" -y -strict experimental -f mp4 \
	                -c:v libx264 -b:v "${ENCODING_SETTINGS_FHD[$x+1]}k" \
	                -c:a libfdk_aac -b:a "${ENCODING_SETTINGS_FHD[$x+3]}k" -ac "${ENCODING_SETTINGS_FHD[$x+2]}" \
	                -r "${ENCODING_SETTINGS_FHD[$x+4]}" \
	                -vf scale="-2:${ENCODING_SETTINGS_FHD[$x+0]}" \
	                -threads 0 "${outputdir}/${ENCODING_SETTINGS_FHD[$x+5]}.tmp" &>> $logfile

			if [ "${CONCAT_FILES}" = true ]; then
				ffmpeg -i "${outputdir}/${ENCODING_SETTINGS_FHD[$x+5]}.tmp" -c copy -bsf:v h264_mp4toannexb -f mpegts "${outputdir}/${ENCODING_SETTINGS_FHD[$x+5]}.ts" &>> $logfile
				CONCAT[${#CONCAT[@]}]="${outputdir}/${ENCODING_SETTINGS_FHD[$x+5]}.ts";
			fi

	        x=$(($x+7));
	done;
	if [ "${CONCAT_FILES}" = true ]; then
		ffmpeg -i "concat:$(join_by \| ${CONCAT[@]})" -c copy -bsf:a aac_adtstoasc "${outputdir}/$(echo ${ENCODING_SETTINGS_FHD[$(($x-2))]} | sed -e 's/^[0-9]\+-//g')" &>> $logfile
		find "${outputdir}" -name '*-1080.mp4.tmp' -or -name '*-1080.mp4.ts' | xargs rm
	else
		find "${outputdir}" -name '*.tmp' -exec bash -c 'mv $0 ${0::-4}' {} \;
	fi
	unset CONCAT;
fi

#echo "${PREFIX}_ENCODE_REMOVING_TORRENT $(transmission-remote 127.0.0.1:9100 --auth=${TRANSMISSION_USERNAME}:${TRANSMISSION_PASSWORD} -t ${hash} --remove-and-delete)" >> $logfile

echo "${PREFIX}_ENCODE_FILES_FOUND_TOTAL ${i}" >> $logfile # total mp4,mkv,avi
echo "${PREFIX}_ENCODE_FILES_ENCODED_TOTAL $(( ${x} / 6 ))" >> $logfile # total mp4,mkv,avi
echo "${PREFIX}_ENCODE_DONE" >> $logfile
