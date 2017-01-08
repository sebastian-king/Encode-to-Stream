# Encode-to-Stream
A script designed to work with Transmission BitTorrent client to encode downloaded media info a streaming format.

The script works with any version of Transmission that supports calling a script when a download is complete. The script then encodes whatever compatible files that were downloaded into a nicely streamable format. This saves one from having to download the media from the Transmission server and instead allows nice and simple streaming.

I have chosen MP4 because it supported by all major browsers, including mobile browsers and the notoriously incompatible iPhone. The bitrates are chosen to allow for the three main tiers of internet speed. Adjust these to your preference, although it is understandly tedius currently to add/change the encoding profiles. I will soon implement a better solution in a better scripting language that properly supports multi dimentional arrays and non-numerical indices.

The log files and prefixes are designed such that the log file can be programatically read and the status of the encodes can be deduced easily by a program. I may include a status watch script (with ETA included) at a later date.

Included is an example Transmission configuration file.

Installation of ffmpeg requires compiling with x264 and fdk-aac support, the process for Ubuntu 16.04 is shown below

```
sudo apt-get install libx264-dev
sudo apt-get install libfdk-aac-dev
sudo apt-get install yasm
mkdir ffmpeg_source
git clone git://source.ffmpeg.org/ffmpeg.git
cd ffmpeg
./configure --enable-gpl --enable-libx264 --enable-nonfree --enable-libfdk-aac
make
make install
ldconfig
cp ffmpeg /usr/bin/
cp ffprobe /usr/bin/
cp ffserver /usr/bin
```

The programs `mediainfo` and `bc` are also used by the script and can be installed using
`apt-get install mediainfo bc`
