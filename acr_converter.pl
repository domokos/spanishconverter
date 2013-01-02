#!/usr/bin/perl

use strict;
use warnings;
use POSIX;
use constant DATETIME => strftime("%d/%m/%Y %H:%M:%S", localtime);
 
my $name;
my $val;
my %properties;

# Read configuration parameters from conf file
open CONFIG, '<', 'acr_converter.conf' or die DATETIME, " Failed to open config file /etc/acr_converter.conf : $!\n";
while (<CONFIG>)
  {
    ($name,$val)=m/(\w+)\s*=(.+)/;
    $properties{$name}=$val;
  }

close(CONFIG);

*OLD_STDOUT = *STDOUT;
*OLD_STDERR = *STDERR;

open my $log_fh, '>>', "$properties{'logfile'}";
*STDOUT = $log_fh;
*STDERR = $log_fh;

# Create a shell script file to get list of modified files from ACR
open REMOTE_SCRIPT, '>' , $properties{'SSH_script_temp_file'} or die DATETIME, " Failed to create shell script file to get list of modified files from ACR : $!\n";

# Write commands into the shell script file to get list of modified files from ACR
print REMOTE_SCRIPT "cd $properties{'ACR_calls_directory_root'}\n";
print REMOTE_SCRIPT "find . -name \"*.xml\" -type f -mmin -$properties{'ACR_call_download_window_minutes'}\n";

close REMOTE_SCRIPT;

# Execute the script remotely to detect modified voice files
my $ssh_child_pid = open SSH_OUTPUT, "$properties{'SSH_binary'} -T $properties{'ACR_user'}\@$properties{'ACR_server'} <$properties{'SSH_script_temp_file'} |" or die DATETIME , " Failed to execute the script remotely to detect modified voice files: $!\n";

my @files_to_download;

# Create a file that will hold scp download commands
open SCP_TEMP_FILE, '>' , $properties{'SCP_script_temp_file'} or die DATETIME, " Failed to create a file that will hold scp download commands: $!\n";

while (<SSH_OUTPUT>)
{
  chomp;

  # Put XML file name in downloader shell script
  s/.\/(.*)/$1/;
  print SCP_TEMP_FILE "$properties{'SCP_binary'} $properties{'ACR_user'}\@$properties{'ACR_server'}:$properties{'ACR_calls_directory_root'}$_ $properties{'SCP_download_temp_target_dir'}\n";

  # Store XML file name for tag extraction
  push @files_to_download, $_;
  
  # Put WAV file name in downloader shell script
  s/(.*)\.xml$/$1.wav/;
  print SCP_TEMP_FILE "$properties{'SCP_binary'} $properties{'ACR_user'}\@$properties{'ACR_server'}:$properties{'ACR_calls_directory_root'}$_ $properties{'SCP_download_temp_target_dir'}\n";
  
  print $_,"\n";
}

my $scp_script_size = tell SCP_TEMP_FILE;

# Close files and remove temp file for SSH
close SSH_OUTPUT;
close SCP_TEMP_FILE;
unlink($properties{'SSH_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove temp file for SSH: $!\n";

if ($scp_script_size >0)
{
  # Download the voice files for conversion by executing the download shell script prepared previously
  system("$properties{'BASH_binary'} $properties{'SCP_script_temp_file'}") == 0 or die DATETIME, " Failed to download the voice files for conversion by executing the download shell script prepared previously: $!\n";

  # Remove the downloader shell script file
  unlink($properties{'SCP_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove the downloader shell script file: $!\n";

  # Create the temp shell script file for segmentation
  open SEGMENTATION_TEMP_SCRIPT_FILE, '>' , $properties{'segmentation_script_temp_file'} or die DATETIME,  " Failed to create the temp shell script file for segmentation: $!\n";
  print SEGMENTATION_TEMP_SCRIPT_FILE "#!$properties{'BASH_binary'}\ncd $properties{'output_directory'}\n";

  my $wav_file_to_convert;

  # Loop through each xml file downloaded
  foreach (@files_to_download)
  {
      # Create the correct path of the XML file where scp downloaded it
      s/^.*\/(\w*.xml)/$properties{'SCP_download_temp_target_dir'}$1/;

      # Create the correct path of the WAV file where scp downloaded it for potential conversion later
      $wav_file_to_convert = $_;
      $wav_file_to_convert =~ s/^(.*).xml$/$1.wav/;

      open XMLFILE, $_;

      my $file_needs_conversion = 0;
      my $segmentation_rule = "";
      
      # Parse the XML file to see if the recording is closed and to extract splitting parameters
      while (<XMLFILE>)
      {
	chomp;
	# File is eligible for conversion if the <noend> tag holds a "false" value
	/<noend>false<\/noend>/ and $file_needs_conversion = 1;
		
	# Find the segmentation tag and extract segmentation rules
	if (/<$properties{'segmentation_tag'}>(.*)<\/$properties{'segmentation_tag'}>/)
	{
	  s/<$properties{'segmentation_tag'}>(.*)<\/$properties{'segmentation_tag'}>/$1/;
	  s/,/ /g;
	  $segmentation_rule = $_;
	}
      }
      close XMLFILE;
      
      $file_needs_conversion and print SEGMENTATION_TEMP_SCRIPT_FILE "$properties{'mp3slpitter_command'} $wav_file_to_convert $segmentation_rule\n";
      print DATETIME, " Voice file: $wav_file_to_convert still recording. No conversion performed.\n" unless $file_needs_conversion;
  }

  close SEGMENTATION_TEMP_SCRIPT_FILE;

  # Perform file conversion and splitting
  system ("$properties{'BASH_binary'} $properties{'segmentation_script_temp_file'}") == 0 or die DATETIME, " Failed to perform file conversion and splitting: $!\n";

  # Remove temp conversion file
  unlink($properties{'segmentation_script_temp_file'}) == 1 or warn DATETIME, " Failed to remove temp conversion file: $!\n";

  # Remove downloaded voice and xml files

  system("$properties{'RM_binary'} -f $properties{'SCP_download_temp_target_dir'}/*.xml") == 0 or warn DATETIME, " Failed to remove downloaded xml files: $!\n";
  system("$properties{'RM_binary'} -f $properties{'SCP_download_temp_target_dir'}/*.wav") == 0 or warn DATETIME, " Failed to remove downloaded voice files: $!\n";
} else {
  print DATETIME, " No voice files match download criteria: exiting cleanly\n";
}

*STDOUT = *OLD_STDOUT;
*STDERR = *OLD_STDERR;
