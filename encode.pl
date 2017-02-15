#!/usr/bin/perl
use strict;
use warnings;

use Cwd 'abs_path';
use File::Copy;
use Time::HiRes qw/gettimeofday/;
use File::Find;
use Sort::Naturally;
use File::Basename;
use IO::Handle;
use File::Copy "cp";

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };
sub rtrim { my $r = shift; $r =~ s/\s+$//; return $r };
sub escape_shell_param($) { #return "'", do { $a=@_; $a=~s/'/'"'"'/gr }, "'";
	my ($par) = @_;
	$par =~ s/'/'"'"'/g;
	return "'$par'";
}

my $date = localtime();
my $timestamp = gettimeofday;

# TODO
# make configuration file so that the file can be compiled and still used
# figure out CONCAT_FILES setting (probably pass using args)
# perhaps look into how the Perl implementation of ffmpeg performs and compatibility with used codecs and hwac

# Configuration section start
my $CONF_DEBUG = 1;
my $CONF_CALL_LOG_FILE = '/home/encode/call.log';
my $CONF_BACKUP_TORRENT_FILES = 1;
my $CONF_TRANSMISSION_USERNAME = "TRANSMISSION_USERNAME";
my $CONF_TRANSMISSION_PASSWORD = "TRANSMISSION_PASSWORD";
my $CONF_PREFIX = "ENCODETOSTREAM";
my $CONF_FFMPEG_BIN = "/usr/bin/ffmpeg";
# no trailing slashes please
my $CONF_ENCODE_OUTPUT_DIR = "/home/encodes";
my $CONF_ENCODE_LOG_DIR = "/home/encode/logs";
my $CONF_TORRENT_BACKUP_DIR = "/home/encode/torrents";
my $CONF_TRANSMISSION_TORRENTS_DIR = "/home/transmission-daemon/.config/transmission-daemon/torrents"; # default location as of at least transmission-daemon v2.84
# Configuration section end
# the below variable's leading space is very important, do not remove.
my $FFMPEG_CMD_WORK = " 2>&1 | stdbuf -i0 -o0 -eL tr '\\r' '\\n'"; # this may need to be modified on some systems, stdbuf <args> is interchangable with expect's unbuffer

my $TR_TORRENT_ID;
my $TR_TORRENT_NAME;
my $TR_TORRENT_HASH;
my $TR_TORRENT_DIR;

if ($CONF_DEBUG) {
        open(my $fh, '>>', $CONF_CALL_LOG_FILE) or die "Could not open call log file (${CONF_CALL_LOG_FILE}): $!";
        print $fh "env TR_TORRENT_ID='$ENV{'TR_TORRENT_ID'}' env TR_TORRENT_HASH='$ENV{'TR_TORRENT_HASH'}' env TR_TORRENT_NAME='$ENV{'TR_TORRENT_NAME'}' env TR_TORRENT_DIR='$ENV{'TR_TORRENT_DIR'}' " . abs_path($0) . " #${date}\n";
        close $fh;
}

if (defined $ENV{'TR_TORRENT_ID'} && defined $ENV{'TR_TORRENT_NAME'} && defined $ENV{'TR_TORRENT_HASH'} && defined $ENV{'TR_TORRENT_DIR'}
		&& $ENV{'TR_TORRENT_ID'} =~ m/^\d+$/i && $ENV{'TR_TORRENT_HASH'} =~ m/^[a-f0-9]{40}$/i && $ENV{'TR_TORRENT_NAME'} =~ m/.+/s && $ENV{'TR_TORRENT_DIR'} =~ m/.+/s) {
	$TR_TORRENT_ID = $ENV{'TR_TORRENT_ID'};
	$TR_TORRENT_NAME = $ENV{'TR_TORRENT_NAME'};
	$TR_TORRENT_HASH = uc $ENV{'TR_TORRENT_HASH'};
	$TR_TORRENT_DIR = $ENV{'TR_TORRENT_DIR'};
} else {
	print "The given environment variables must be the in the format (all checks are case insensitive):\n	TR_TORRENT_ID	/^[a-f0-9]{16}\$/\n	TR_TORRENT_NAME	/^.+\$/\n	TR_TORRENT_HASH	/^[a-f0-9]{40}\$/\n	TR_TORRENT_DIR	/^.+\$/\nIf you don't know what these formats are, please see the reference at http://perldoc.perl.org/perlreref.html\n";
	exit;
}
$TR_TORRENT_DIR = "${TR_TORRENT_DIR}/${TR_TORRENT_NAME}";

my $ENCODE_OUTPUT_DIR = "${CONF_ENCODE_OUTPUT_DIR}/${TR_TORRENT_HASH}";
my $ENCODE_LOG_FILE = "${CONF_ENCODE_LOG_DIR}/${TR_TORRENT_HASH}.log";

local $SIG{__DIE__} = sub {
	my ($message) = @_;
	open (my $fh, '>>', $ENCODE_LOG_FILE);
	print $fh localtime() . ": " . $message;
	close $fh;
};

if ($CONF_BACKUP_TORRENT_FILES) {
	my $torrent_id = lc substr $TR_TORRENT_HASH, 0, 16;
	copy("${CONF_TRANSMISSION_TORRENTS_DIR}/${TR_TORRENT_NAME}.${torrent_id}.torrent", "${CONF_TORRENT_BACKUP_DIR}/${TR_TORRENT_HASH}.torrent") or die "Failed to backup .torrent file: $!"; # possibly not necessary to die here as this won't affect encoding
}

# 1 if we are encoding something like a film which might have cd1 and cd2 or part1 and part,
# 0 if we are encoding something like multiple tv shows which are all in individual files.
my $CONCAT_FILES = 1; # not really a config parameter, should be programatically set

if ($CONF_DEBUG) {
	print "DEBUG: ${CONF_DEBUG}\nID: ${TR_TORRENT_ID}\nNAME: ${TR_TORRENT_NAME}\nHASH: ${TR_TORRENT_HASH}\nDIR: ${TR_TORRENT_DIR}\nDATE: ${date}\nCONCAT: ${CONCAT_FILES}\n";
}

open (my $log, '>', $ENCODE_LOG_FILE) or die "Could not open log file (${ENCODE_LOG_FILE}): $!";

if (!-d $ENCODE_OUTPUT_DIR) {
	mkdir $ENCODE_OUTPUT_DIR or die "Could not create output directory (${ENCODE_OUTPUT_DIR}): $!";
}

print $log "${CONF_PREFIX}_ENCODE_START " . trim(`date +%s`) . " (${date})\n";
print $log "${CONF_PREFIX}_ENCODE_INPUT_NAME ${TR_TORRENT_NAME}\n";
print $log "${CONF_PREFIX}_ENCODE_INPUT_DIR ${TR_TORRENT_DIR}\n";
print $log "${CONF_PREFIX}_ENCODE_OUTPUT_DIR ${ENCODE_OUTPUT_DIR}\n";
print $log "${CONF_PREFIX}_ENCODE_LOG_FILE ${ENCODE_LOG_FILE}\n";

print $log "${CONF_PREFIX}_ENCODE_CONCAT_FILES ${CONCAT_FILES}\n";

# not necessary, but for some reason setting the seed ratio to 0 doesn't pause on finish
# comment the following two lines of code to keep the torrents seeding
# WARNING: transmission seems to output some funny bytes at the end of it's 401: Unauthorised output, detailed here:
my $output = trim(`transmission-remote 127.0.0.1:9100 --auth=${CONF_TRANSMISSION_USERNAME}:${CONF_TRANSMISSION_PASSWORD} -t ${TR_TORRENT_HASH} --stop 2>&1`);
print $log "${CONF_PREFIX}_ENCODE_STOPPING_TORRENT ${output}\n";

my @files_found;
find(sub { -f and push @files_found, $File::Find::name } , $TR_TORRENT_DIR);

@files_found = grep (/\.(mp4|m4v|mkv|avi)$/, @files_found);
@files_found = nsort(@files_found); # nsort tries to list the files in a human-sensible way

if (scalar @files_found eq 0) {
	die "${CONF_PREFIX}_FAIL Unable to find any encodable files\n";
}

my %ENCODE_SETTINGS;

$ENCODE_SETTINGS{"0_FHD"}{Height} = 1080;
$ENCODE_SETTINGS{"0_FHD"}{VideoBitrate} = 4000;
$ENCODE_SETTINGS{"0_FHD"}{AudioBitrate} = 128;
$ENCODE_SETTINGS{"0_FHD"}{AudioChannels} = 2;

$ENCODE_SETTINGS{"1_HDR"}{Height} = 720;
$ENCODE_SETTINGS{"1_HDR"}{VideoBitrate} = 1500;
$ENCODE_SETTINGS{"1_HDR"}{AudioBitrate} = 128;
$ENCODE_SETTINGS{"1_HDR"}{AudioChannels} = 2;

$ENCODE_SETTINGS{"2_SD"}{Height} = 480;
$ENCODE_SETTINGS{"2_SD"}{VideoBitrate} = 800;
$ENCODE_SETTINGS{"2_SD"}{AudioBitrate} = 64;
$ENCODE_SETTINGS{"2_SD"}{AudioChannels} = 1;

$ENCODE_SETTINGS{"3_LOW"}{Height} = -1;
$ENCODE_SETTINGS{"3_LOW"}{VideoBitrate} = 800;
$ENCODE_SETTINGS{"3_LOW"}{AudioBitrate} = 64;
$ENCODE_SETTINGS{"3_LOW"}{AudioChannels} = 1;

$ENCODE_SETTINGS{"4_RAW"}{Height} = -1;
$ENCODE_SETTINGS{"4_RAW"}{VideoBitrate} = -1;
$ENCODE_SETTINGS{"4_RAW"}{AudioBitrate} = -1;
$ENCODE_SETTINGS{"4_RAW"}{AudioChannels} = 1;

my %TO_ENCODE;

my $i = 0;
for my $file (@files_found) {
	$i += 1;

	if ($file =~ /sample/i) {
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_X_IS_SAMPLE TRUE\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_X_SAMPLE $file\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_X_IGNORING_SAMPLES TRUE\n";
		$i -= 1;
	} else {
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_FILE ${file}\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_FORMAT " . substr($file, -4, length $file) . "\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_IS_SAMPLE FALSE\n";

		my $AudioBitrate = trim(`mediainfo --Output=Audio\\;%BitRate% "${file}"`);
		my $VideoBitrate = trim(`mediainfo --Output=Video\\;%BitRate% "${file}"`);
		my $OverallBitrate = trim(`mediainfo --Output=General\\;%OverallBitRate% "${file}"`);
		if ($OverallBitrate !~ /^\d+$/) {
			die "${CONF_PREFIX}_FAIL Unable to determine the bit rate of file '${file}'";
		}
		if ($VideoBitrate !~ /^\d+$/ || $AudioBitrate !~ /^\d+$/) {
			$AudioBitrate = $OverallBitrate * 0.1; # 10% of bit rate to be used for audio, int(abs()) works because bittrate will never be negative
			$VideoBitrate = $OverallBitrate * 0.9; # 90% of bit rate to be used for video
			print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_INTERPOLATED_BITRATE TRUE\n";
		} else {
			print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_INTERPOLATED_BITRATE FALSE\n";
		}
		$AudioBitrate = int($AudioBitrate / 1000);
		$VideoBitrate = int($VideoBitrate / 1000);
		$OverallBitrate = int($OverallBitrate / 1000);

		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_BITRATE ${AudioBitrate}\n";
                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_VIDEO_BITRATE ${VideoBitrate}\n";
                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_OVERALL_BITRATE ${OverallBitrate}\n";

		my $Height = trim(`mediainfo --Output=Video\\;%Height% "${file}"`);
		my $FrameRate = trim(`mediainfo --Output=Video\\;%FrameRate% "${file}"`);
		my $AudioChannels = trim(`mediainfo --Output=Audio\\;%Channels% "${file}"`);

		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_HEIGHT ${Height}\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_FRAME_RATE ${FrameRate}\n";
		print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS ${AudioChannels}\n";

		if ($FrameRate > 25) {
                        $FrameRate = 25;
                        print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_FRAME_RATE_FORCED TRUE (${FrameRate})\n";
                } else {
			print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_FRAME_RATE_FORCED FALSE\n";
		}

		my $ENCODE_AUDIO_CHANNELS;

		foreach my $key (sort keys %ENCODE_SETTINGS) {

			my $name = $key;
                        $name =~ s/^(.+)_//;
			my $n = $key;
			$n =~ s/^(\d+)_.+/$1/;

			if ($ENCODE_SETTINGS{$key}{'Height'} > 0) {

				if ($Height > $ENCODE_SETTINGS{$key}{'Height'} * 0.95) { # a lot of files seem to be encoded to just under the standards so we allow for a little leeway and a slight up-encode

					if ($AudioChannels < $ENCODE_SETTINGS{$key}{'AudioChannels'}) {
                                	        $ENCODE_AUDIO_CHANNELS = $AudioChannels;
                                	        print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS_FORCED TRUE ($ENCODE_SETTINGS{$key}{'AudioChannels'} => ${AudioChannels})\n";
                                	} else {
						$ENCODE_AUDIO_CHANNELS = $ENCODE_SETTINGS{$key}{'AudioChannels'};
                                	        print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS_FORCED FALSE\n";
                                	}

					$TO_ENCODE{$n}{$i}{Name} = $name;
					$TO_ENCODE{$n}{$i}{Height} = $ENCODE_SETTINGS{$key}{Height};
					$TO_ENCODE{$n}{$i}{AudioChannels} = $ENCODE_AUDIO_CHANNELS;
					$TO_ENCODE{$n}{$i}{FrameRate} = $FrameRate;
					$TO_ENCODE{$n}{$i}{File} = $file;
					if ($VideoBitrate > $ENCODE_SETTINGS{$key}{'VideoBitrate'}) {
						$TO_ENCODE{$n}{$i}{VideoBitrate} = $ENCODE_SETTINGS{$key}{VideoBitrate};
						$TO_ENCODE{$n}{$i}{AudioBitrate} = $ENCODE_SETTINGS{$key}{AudioBitrate};
						$TO_ENCODE{$n}{$i}{Filename} = "${i}-$ENCODE_SETTINGS{$key}{Height}.mp4";
						print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: $ENCODE_SETTINGS{$key}{'Height'}, V: $ENCODE_SETTINGS{$key}{'VideoBitrate'}k, A: $ENCODE_AUDIO_CHANNELS channel(s) $ENCODE_SETTINGS{$key}{'AudioBitrate'}k, F: ${FrameRate} [TRUE $name]\n";
					} else {
						$TO_ENCODE{$n}{$i}{VideoBitrate} = $VideoBitrate;
                                                $TO_ENCODE{$n}{$i}{AudioBitrate} = $AudioBitrate;
                                                $TO_ENCODE{$n}{$i}{Filename} = "${i}-$ENCODE_SETTINGS{$key}{Height}-LOW.mp4";
						print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: $ENCODE_SETTINGS{$key}{'Height'}, V: ${VideoBitrate}k, A: $ENCODE_AUDIO_CHANNELS channel(s) ${AudioBitrate}k, F: ${FrameRate} [LOW BITRATE $name]\n";
					}

				}
			} else {
				if (keys %TO_ENCODE == 0) {

					if ($AudioChannels < $ENCODE_SETTINGS{$key}{'AudioChannels'}) {
                                                $ENCODE_AUDIO_CHANNELS = $AudioChannels;
                                                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS_FORCED TRUE ($ENCODE_SETTINGS{$key}{'AudioChannels'} => ${AudioChannels})\n";
                                        } else {
                                                $ENCODE_AUDIO_CHANNELS = $ENCODE_SETTINGS{$key}{'AudioChannels'};
                                                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_AUDIO_CHANNELS_FORCED FALSE\n";
                                        }

					$TO_ENCODE{$n}{$i}{Name} = $name;
					$TO_ENCODE{$n}{$i}{Height} = $Height;
                                        $TO_ENCODE{$n}{$i}{AudioChannels} = $ENCODE_AUDIO_CHANNELS;
                                        $TO_ENCODE{$n}{$i}{FrameRate} = $FrameRate;
                                        $TO_ENCODE{$n}{$i}{File} = $file;
					if ($VideoBitrate > $ENCODE_SETTINGS{$key}{'VideoBitrate'}) {
						$TO_ENCODE{$n}{$i}{VideoBitrate} = $ENCODE_SETTINGS{$key}{VideoBitrate};
                                                $TO_ENCODE{$n}{$i}{AudioBitrate} = $ENCODE_SETTINGS{$key}{AudioBitrate};
                                                $TO_ENCODE{$n}{$i}{Filename} = "${i}-${name}.mp4";
                                                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: ${Height}, V: $ENCODE_SETTINGS{$key}{'VideoBitrate'}k, A: $ENCODE_AUDIO_CHANNELS channel(s) $ENCODE_SETTINGS{$key}{'AudioBitrate'}k, F: ${FrameRate} [$name]\n";
                                        } else {
						$TO_ENCODE{$n}{$i}{VideoBitrate} = $ENCODE_SETTINGS{$key}{VideoBitrate};
                                                $TO_ENCODE{$n}{$i}{AudioBitrate} = $ENCODE_SETTINGS{$key}{AudioBitrate};
                                                $TO_ENCODE{$n}{$i}{Filename} = "${i}-${name}.mp4";
                                                print $log "${CONF_PREFIX}_ENCODE_FILE_FOUND_${i}_ENCODE_SETTINGS H: ${Height}, V: ${VideoBitrate}k, A: $ENCODE_AUDIO_CHANNELS channel(s) ${AudioBitrate}k, F: ${FrameRate} [$name]\n";
                                        }
				}
			}
		}
	}
}

print $log "${CONF_PREFIX}_ENCODE_FILES_COUNT ${i}\n";

print $log "${CONF_PREFIX}_ENCODE_FILE_LIST_START\n" . join("\n", @files_found) . "\n${CONF_PREFIX}_ENCODE_FILE_LIST_END\n";

# encode highest number first
foreach my $QualityLevel (reverse sort keys %TO_ENCODE) {
	my @CONCAT;
	foreach my $FileNumber (sort keys %{$TO_ENCODE{$QualityLevel}}) {
		print $log "${PREFIX}_ENCODE_STATUS ENCODING ${FileNumber}/$TO_ENCODE{$QualityLevel}{$FileNumber}{Name}\n";
		# now lets encode
		my @ffmpeg_cmd = ($CONF_FFMPEG_BIN);
		push @ffmpeg_cmd, "-i", escape_shell_param($TO_ENCODE{$QualityLevel}{$FileNumber}{File});
		push @ffmpeg_cmd, "-y";
		push @ffmpeg_cmd, "-strict", "experimental"; # check necessity
		push @ffmpeg_cmd, "-f", "mp4";
		push @ffmpeg_cmd, "-c:v", "libx264";
		push @ffmpeg_cmd, "-b:v", "$TO_ENCODE{$QualityLevel}{$FileNumber}{VideoBitrate}k";
		push @ffmpeg_cmd, "-c:a", "libfdk_aac";
		push @ffmpeg_cmd, "-b:a", "$TO_ENCODE{$QualityLevel}{$FileNumber}{AudioBitrate}k";
		push @ffmpeg_cmd, "-ac", "$TO_ENCODE{$QualityLevel}{$FileNumber}{AudioChannels}";
		push @ffmpeg_cmd, "-r", "$TO_ENCODE{$QualityLevel}{$FileNumber}{FrameRate}";
		push @ffmpeg_cmd, "-vf", "scale='-2:$TO_ENCODE{$QualityLevel}{$FileNumber}{Height}'";
		push @ffmpeg_cmd, "-threads", "0";
		push @ffmpeg_cmd, escape_shell_param($ENCODE_OUTPUT_DIR . "/" . $TO_ENCODE{$QualityLevel}{$FileNumber}{Filename} . ".tmp");

		open FFMPEG, "-|", join(' ', @ffmpeg_cmd) . $FFMPEG_CMD_WORK or die $!;
		while (<FFMPEG>) { # in this loop we could process the ffmpeg output
			print $log $_;
			$log->flush();
		}

		if ($CONCAT_FILES) {
			my @concat_cmd = ($CONF_FFMPEG_BIN);
			push @concat_cmd, "-i", pop(@ffmpeg_cmd);
			push @concat_cmd, "-y";
			push @concat_cmd, "-c", "copy";
			push @concat_cmd, "-bsf:v", "h264_mp4toannexb";
			push @concat_cmd, "-f", "mpegts";
			push @concat_cmd, escape_shell_param($ENCODE_OUTPUT_DIR . "/" . $TO_ENCODE{$QualityLevel}{$FileNumber}{Filename} . ".ts");

			open FFMPEG, "-|", join(' ', @concat_cmd) . $FFMPEG_CMD_WORK or die $!;
                	while (<FFMPEG>) {
                		print $log $_;
				$log->flush();
                	}

			push @CONCAT, pop(@concat_cmd);			
		}

	}

	if ($CONCAT_FILES) {
		my @concat_cmd = ($CONF_FFMPEG_BIN);
		push @concat_cmd, "-i", "concat:" . join("|", @CONCAT);
		push @concat_cmd, "-y";
		push @concat_cmd, "-c", "copy";
		push @concat_cmd, "-bsf:a", "aac_adtstoasc";
		push @concat_cmd, escape_shell_param( ( do { dirname($CONCAT[0])=~s/^'//r } . "/" . do { basename($CONCAT[0])=~s/^.+?-(.+)\.ts[']?$/$1/r; } ) );

		open FFMPEG, "-|", join(' ', @concat_cmd) . $FFMPEG_CMD_WORK or die $!;
                while (<FFMPEG>) {
                        print $log $_;
                        $log->flush();
                }

		# delete .ts and .tmp
		my @cleanup_files;
		find(sub { -f and push @cleanup_files, $File::Find::name } , $ENCODE_OUTPUT_DIR);
		@cleanup_files = grep (/\.(ts|tmp)$/, @cleanup_files);
		for my $file (@cleanup_files) {
			#unlink($file);
		}
	} else {
		# move .tmp to .mp4
		my @cleanup_files;
		find(sub { -f and push @cleanup_files, $File::Find::name } , $ENCODE_OUTPUT_DIR);
		@cleanup_files = grep (/\.tmp$/, @cleanup_files);
		for my $file (@cleanup_files) {
			#move
			move($file, $file=~s/\.tmp$//r);
		}
        }

}

print $log "${CONF_PREFIX}_ENCODE_EXECUTION TIME " . (gettimeofday - $timestamp) . "\n";

close $log;
